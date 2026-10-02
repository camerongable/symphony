defmodule SymphonyElixir.FactorySchedulerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{
    Contract,
    ContractChat,
    Control,
    DesktopRequest,
    IntakeLedger,
    ModelRouter,
    MrFeedback,
    MrFeedbackLedger
  }

  alias SymphonyElixir.Factory.{Prompt, RunLedger}
  alias SymphonyElixir.Factory.{Scheduler, Store, TaskLedger}

  defmodule FakeControllerTask do
    @spec run(map(), Path.t(), map(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(_factory, _workspace, _issue, prompt, _schema, opts) do
      send(self(), {:controller_prompt, prompt})
      send(self(), {:controller_options, opts})
      if String.contains?(prompt, "Perform exactly this Jira controller operation"), do: send(self(), {:jira_write_options, opts})

      case Process.get(:factory_controller_responses) do
        [response | rest] ->
          Process.put(:factory_controller_responses, rest)
          {:ok, response}

        _other ->
          {:ok, Process.get(:factory_controller_response)}
      end
    end
  end

  defmodule FakeJiraConnector do
    @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def call("jira_search", %{"jql" => jql}, _opts) do
      send(self(), {:jira_search_jql, jql})

      case Process.get(:factory_jira_search) do
        nil ->
          response = next_controller_response()
          snapshots = response["snapshot_json"] |> decode_snapshots()
          Process.put(:factory_jira_search_hits, snapshots)
          {:ok, %{"issues" => snapshots, "total" => length(snapshots)}}

        page ->
          {:ok, page}
      end
    end

    def call("jira_get_issue", %{"issue_key" => issue_key, "include" => "comments"}, _opts) do
      issue =
        Process.get(:factory_jira_issue) ||
          Enum.find(Process.get(:factory_jira_search_hits, []), &(&1["key"] == issue_key))

      case issue do
        %{"key" => ^issue_key} = issue -> {:ok, issue}
        _other -> {:error, :fake_jira_issue_missing}
      end
    end

    def call("jira_add_comment", %{"issue_key" => issue_key, "body" => body}, _opts) do
      with {:ok, issue} <- call("jira_get_issue", %{"issue_key" => issue_key, "include" => "comments"}, []) do
        id = Integer.to_string(length(issue["comments"]) + 1)
        Process.put(:factory_jira_issue, Map.update!(issue, "comments", &(&1 ++ [%{"id" => id, "text" => body}])))
        {:ok, %{"id" => id}}
      end
    end

    def call("jira_update_issue", %{"issue_key" => issue_key, "fields" => fields}, _opts) when is_binary(fields) do
      %{"labels" => labels} = Jason.decode!(fields)

      with {:ok, issue} <- call("jira_get_issue", %{"issue_key" => issue_key, "include" => "comments"}, []) do
        Process.put(:factory_jira_issue, Map.put(issue, "labels", labels))
        {:ok, %{}}
      end
    end

    defp next_controller_response do
      case Process.get(:factory_controller_responses) do
        [response | rest] ->
          Process.put(:factory_controller_responses, rest)
          response

        _other ->
          Process.get(:factory_controller_response)
      end
    end

    defp decode_snapshots(value) when is_binary(value), do: value |> Jason.decode!() |> decode_snapshots()
    defp decode_snapshots(value) when is_list(value), do: value
  end

  defmodule FakeReviewJiraReader do
    @spec search(String.t(), keyword()) :: {:error, atom()}
    def search(_jql, _opts), do: {:error, :queue_offline}

    @spec issue(String.t(), keyword()) :: {:ok, map()}
    def issue(key, opts) do
      send(self(), {:review_issue_read, key})
      send(self(), {:review_issue_connector, Keyword.get(opts, :connector)})
      {:ok, Process.get(:review_issue)}
    end
  end

  defmodule FakeReviewGitLabReader do
    @spec fetch(map(), map(), keyword()) :: {:ok, map()}
    def fetch(route, run, _opts) do
      send(self(), {:review_mr_read, run["run_id"]})

      {:ok,
       %{
         mr: %{
           "project" => route["gitlab_project"],
           "iid" => run["mr_iid"],
           "web_url" => run["mr_url"],
           "source_branch" => run["branch"],
           "sha" => run["candidate_sha"],
           "state" => "opened"
         },
         discussions: [
           %{
             "id" => "discussion-1",
             "notes" => [
               %{
                 "id" => 51,
                 "body" => Process.get(:review_note_body, "@Symphony please check this"),
                 "updated_at" => "2026-09-30T10:00:00Z",
                 "author" => %{"id" => 12}
               }
             ]
           }
         ]
       }}
    end
  end

  defmodule FakeReviewConsumer do
    @spec process_one(map(), keyword()) :: {:ok, :pending}
    def process_one(_context, _opts) do
      send(self(), :review_consumer_called)
      {:ok, :pending}
    end
  end

  defmodule FakeTaskLauncher do
    @spec launch(term(), term(), map(), map(), Path.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def launch(store, _supervisor, run, _issue, workspace, prompt, _schema, opts) do
      attrs = %{
        task_key: opts[:task_key],
        run_id: run["run_id"],
        stage: opts[:stage],
        role: opts[:role],
        status: "RUNNING",
        model_provider: "codex",
        model_class: "test",
        model: "gpt-test",
        reasoning_effort: "medium",
        routing_reason: "test",
        codex_project_id: opts[:project_id],
        codex_section_id: opts[:section_id],
        workspace_sha: opts[:expected_sha],
        prompt_sha256: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
      }

      case TaskLedger.get(store, opts[:task_key]) do
        {:ok, _task} ->
          TaskLedger.update(store, opts[:task_key], attrs |> Map.delete(:workspace_sha) |> Map.put(:output_json, nil))

        {:error, :unknown_task} ->
          TaskLedger.register(store, attrs)
      end

      send(self(), {:stage_launch, run["run_id"], workspace, prompt, opts})
      pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: pid, ref: make_ref(), task_key: opts[:task_key], route: %{}}}
    end
  end

  defmodule FakeCleanup do
    @spec authorization_candidates(term(), map(), String.t()) :: [map()]
    def authorization_candidates(_store, _policy, repo_key) do
      send(self(), {:cleanup_candidates_requested, repo_key})

      Process.get(:factory_cleanup_candidates, [])
      |> Enum.filter(&(&1["repo_key"] == repo_key))
    end

    @spec authorize(term(), map(), String.t(), String.t() | nil, String.t() | nil, keyword()) :: {:ok, map()}
    def authorize(_store, _policy, run_id, jira_status, mr_state, _opts \\ []) do
      send(self(), {:cleanup_authorized, run_id, jira_status, mr_state})
      {:ok, %{"run_id" => run_id, "cleanup_authorized" => 1}}
    end

    @spec apply(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def apply(_store, _policy, run_id, _opts \\ []) do
      send(self(), {:cleanup_applied, run_id})
      {:ok, %{result: "CLEANED", run_id: run_id}}
    end

    @spec ensure_capacity(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def ensure_capacity(_store, _policy, repo_key, _opts \\ []) do
      {:ok, %{repo_key: repo_key, available_writer_slots: 1, cleaned: []}}
    end

    @spec hibernate(term(), map(), String.t(), keyword()) :: {:ok, map()}
    def hibernate(_store, _policy, run_id, _opts \\ []) do
      send(self(), {:hibernate, run_id})
      {:ok, %{result: "SKIPPED", run_id: run_id, reason: "test"}}
    end
  end

  defmodule FakeWorktree do
    @candidate String.duplicate("a", 40)

    @spec base_sha(map()) :: {:ok, String.t()}
    def base_sha(_route), do: {:ok, Process.get(:factory_base_sha, String.duplicate("b", 40))}

    @spec ensure_writer(map(), String.t(), String.t()) :: {:ok, map()}
    def ensure_writer(route, issue_key, run_id) do
      path = Path.join(route["workspace_root"], "#{issue_key}-#{run_id}-writer")
      File.mkdir_p!(path)
      send(self(), {:ensure_writer, route, issue_key, run_id})
      {:ok, %{path: path, branch: route["branch"], base_branch: "master", head: @candidate}}
    end

    @spec candidate(Path.t(), String.t()) :: {:ok, String.t()}
    def candidate(path, _base), do: {:ok, Process.get({:factory_candidate, path}, @candidate)}

    def commit_native_slice(_route, path, branch, parent, paths, message) do
      send(self(), {:commit_native_slice, path, branch, parent, paths, message})

      if paths == [],
        do: {:error, :native_slice_intent_invalid},
        else: {:ok, %{sha: Process.get({:factory_candidate, path}, @candidate)}}
    end

    @spec create_detached(map(), String.t(), String.t(), String.t(), String.t()) :: {:ok, Path.t()}
    def create_detached(route, _issue_key, run_id, stage, sha) do
      send(self(), {:create_detached, stage, sha})
      path = Path.join(route["workspace_root"], "#{run_id}-#{stage}")
      pinned = Process.get({:factory_detached_sha, path})

      if pinned != nil and pinned != sha do
        {:error, :detached_worktree_mismatch}
      else
        File.mkdir_p!(path)
        Process.put({:factory_detached_sha, path}, sha)
        {:ok, path}
      end
    end

    @spec create_detached_pinned(map(), String.t(), String.t(), String.t(), String.t()) :: {:ok, Path.t()}
    def create_detached_pinned(route, issue_key, run_id, stage, sha) do
      path = Path.join(route["workspace_root"], "#{run_id}-#{stage}")

      if File.dir?(path) do
        {:ok, path}
      else
        create_detached(route, issue_key, run_id, stage, sha)
      end
    end

    @spec validate_detached(map(), Path.t()) :: {:ok, map()}
    def validate_detached(_route, path), do: {:ok, %{path: path, sha: Process.get({:factory_detached_sha, path})}}

    @spec validate_native(map(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
    def validate_native(_route, path, opts) do
      send(self(), {:validate_native, path, opts})

      if File.dir?(path) do
        branch = if Process.get({:native_detached, path}, false), do: "", else: opts[:expected_branch]
        head = Process.get({:native_head_sha, path}, opts[:expected_sha])

        cond do
          opts[:expected_branch] && branch != opts[:expected_branch] ->
            {:error, {:native_worktree_branch_mismatch, opts[:expected_branch], branch}}

          opts[:expected_sha] && head != opts[:expected_sha] ->
            {:error, {:native_worktree_sha_mismatch, opts[:expected_sha], head}}

          true ->
            {:ok, %{path: Path.expand(path), sha: head}}
        end
      else
        {:error, :native_worktree_missing}
      end
    end

    @spec remove_detached(map(), Path.t()) :: :ok
    def remove_detached(_route, path) do
      send(self(), {:removed_detached, path})
      :ok
    end

    @spec reachable?(map(), String.t()) :: boolean()
    def reachable?(_route, @candidate), do: true

    @spec push_exact(map(), Path.t(), String.t(), String.t()) :: {:ok, map()}
    def push_exact(_route, _writer, branch, @candidate) do
      send(self(), {:push_exact, branch, @candidate})
      {:ok, %{branch: branch, sha: @candidate}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "factory-scheduler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    database = Path.join(root, "factory.sqlite")
    {:ok, store} = Store.start_link(database: database)

    factory = %{
      enabled: true,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-1",
      branch_prefix: "cgable",
      queue: %{
        "assignee" => "currentUser()",
        "statuses" => ["READY", "TO DO"],
        "factory_labels" => ["spec-needed", "ai-ready", "ai-running", "ai-testing"],
        "projects" => [],
        "epics" => []
      },
      repositories: %{
        "grail" => %{
          "path" => root,
          "base_branch" => "master",
          "codex_project_id" => "project-grail",
          "gitlab_project" => "grailbio/grail",
          "route_labels" => ["repo-grail"]
        }
      },
      models: %{},
      cleanup: %{},
      hibernation: %{},
      manual_validation: %{
        "enabled" => true,
        "allowed_environments" => ["cpp-test"],
        "require_slack_coordination" => true,
        "required_apps" => ["polaris-app"],
        "startup_timeout_ms" => 45_000,
        "allow_production" => false,
        "allow_database_ddl" => false
      },
      maximum_specifiers: 2,
      specification_authorization_mode: "human_confirmation",
      maximum_writers: 2,
      maximum_validators: 2,
      writer_disk_gb: 1,
      maximum_implementation_iterations: 8,
      maximum_code_repair_rounds: 2,
      maximum_validation_repair_rounds: 2,
      stale_task_minutes: 90
    }

    context = %{
      factory: factory,
      store: store,
      task_supervisor: self(),
      control_server: self(),
      active_task_keys: MapSet.new(),
      recipient: self(),
      workspace_root: root
    }

    on_exit(fn -> File.rm_rf(root) end)
    %{context: context, store: store, root: root}
  end

  test "review feedback still polls when unrelated Jira intake fails", %{context: context, store: store} do
    run = %{
      run_id: "review-42",
      issue_key: "PPL-123",
      kind: "DELIVERY",
      state: "READY_FOR_REVIEW",
      repo_key: "grail",
      branch: "factory/PPL-123",
      candidate_sha: String.duplicate("a", 40),
      mr_iid: 123,
      mr_url: "https://gitlab.example/grailbio/grail/-/merge_requests/123"
    }

    assert {:ok, _registered} = RunLedger.register(store, run)
    Process.put(:review_issue, snapshot(["repo-grail", "ai-review"]))

    factory =
      context.factory
      |> Map.put(:task_transport, "desktop_broker")
      |> Map.put(:review_feedback, %{"allowed_author_ids" => [12], "bot_author_id" => 99})

    assert {:error, :queue_offline} =
             Scheduler.tick(%{context | factory: factory},
               jira_reader: FakeReviewJiraReader,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               cleanup: FakeCleanup
             )

    assert_received {:review_issue_read, "PPL-123"}
    assert_received {:review_issue_connector, SymphonyElixir.Factory.JiraMcpConnector}
    assert_received {:review_mr_read, "review-42"}
    assert_received :review_consumer_called
    assert [receipt] = MrFeedbackLedger.pending(store)
    assert receipt["note_id"] == 51

    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'CLAIMED', request_key = 'feedback-request'")

    assert {:ok, %{launches: [], events: []}} =
             Scheduler.tick(%{context | factory: factory},
               jira_reader: FakeReviewJiraReader,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               cleanup: FakeCleanup
             )

    assert_receive first_feedback_action
    assert first_feedback_action == :review_consumer_called

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.query!(
      store,
      "INSERT INTO desktop_requests (request_key, target_kind, target_key, action, status, payload_sha256, codex_project_id, model, reasoning_effort, title, prompt, schema_json, cwd, metadata_json, created_at, updated_at) VALUES ('feedback-request', 'CONTROLLER', 'assigned-jira-work', 'FOLLOWUP', 'PENDING', ?, 'projectless', 'gpt-test', 'medium', 'Controller', 'question', '{}', '/tmp/controller', '{}', ?, ?)",
      [String.duplicate("a", 64), now, now]
    )

    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'SUPERSEDED'")

    assert {:error, :queue_offline} =
             Scheduler.tick(%{context | factory: factory},
               jira_reader: FakeReviewJiraReader,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               cleanup: FakeCleanup
             )

    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'COMPLETE'")

    assert {:error, :queue_offline} =
             Scheduler.tick(%{context | factory: factory},
               jira_reader: FakeReviewJiraReader,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               cleanup: FakeCleanup
             )
  end

  test "verified review rework pushes the existing MR branch and queues exact-thread replies", %{context: context, store: store, root: root} do
    candidate = String.duplicate("a", 40)
    prior = String.duplicate("b", 40)
    writer_path = Path.join(root, "review-writer")
    File.mkdir_p!(writer_path)

    contract = Contract.bind("PPL-123", 1, "# Contract\n\n## Acceptance Criteria\n- AC-1: works")
    snapshot = authorized_snapshot(contract, ["ai-review", "repo-grail"]) |> Map.put("status", "In Dev")
    Process.put(:factory_controller_response, intake_response(snapshot))
    Process.put(:factory_jira_issue, snapshot)

    factory =
      context.factory
      |> Map.put(:task_transport, "desktop_broker")
      |> Map.put(:review_feedback, %{"enabled" => false})

    note = %{
      "id" => 51,
      "body" => "@Symphony please check this",
      "updated_at" => "2026-09-30T10:00:00Z",
      "author" => %{"id" => 12}
    }

    discussion = %{"id" => "discussion-1", "notes" => [note]}
    route = Map.put(factory.repositories["grail"], "repo_key", "grail")
    mr_url = "https://gitlab.example/grailbio/grail/-/merge_requests/123"
    old_mr = %{"project" => route["gitlab_project"], "iid" => 123, "web_url" => mr_url, "source_branch" => "cgable/PPL-123-factory-work", "sha" => prior, "state" => "opened"}

    old_run = %{
      "run_id" => "review-push-run",
      "issue_key" => "PPL-123",
      "kind" => "DELIVERY",
      "state" => "READY_FOR_REVIEW",
      "repo_key" => "grail",
      "branch" => old_mr["source_branch"],
      "candidate_sha" => prior,
      "mr_iid" => 123,
      "mr_url" => mr_url
    }

    {:ok, feedback} = MrFeedback.candidate(old_run, route, snapshot, old_mr, discussion, note, [12], 99)

    feedback_json =
      Jason.encode!([
        %{
          "feedback_key" => feedback.feedback_key,
          "discussion_id" => discussion["id"],
          "note_id" => note["id"],
          "note_updated_at" => note["updated_at"],
          "author_id" => 12,
          "body_sha256" => feedback.body_sha256,
          "body" => note["body"]
        }
      ])

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "review-push-run",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "REVIEW_PUSHING",
               repo_key: "grail",
               repo_path: route["path"],
               base_branch: "master",
               branch: old_mr["source_branch"],
               worktree: writer_path,
               candidate_sha: candidate,
               review_base_sha: prior,
               review_feedback_json: feedback_json,
               mr_iid: 123,
               mr_url: mr_url,
               snapshot_json: Jason.encode!(snapshot),
               contract_markdown: contract.markdown,
               contract_sha256: contract.sha256,
               spec_revision: 1,
               verifier_round: 1,
               factory_owned: false
             })

    assert {:ok, verifier_task} =
             TaskLedger.register(store, %{
               task_key: "review-push-run:change-verifier:1",
               run_id: run["run_id"],
               stage: "VERIFYING",
               role: "change-verifier",
               status: "CONSUMED",
               model_provider: "codex",
               model_class: "test",
               model: "gpt-test",
               reasoning_effort: "medium",
               routing_reason: "test",
               codex_project_id: "project-grail",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _task} =
             TaskLedger.update(store, verifier_task["task_key"], %{
               output_json: Jason.encode!(%{"status" => "PASS", "candidate_sha" => candidate})
             })

    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(store, feedback)
    batch_key = "review-batch-1"
    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'REWORKING', review_batch_key = ?", [batch_key])

    assert {:ok, _result} =
             Scheduler.tick(%{context | factory: factory},
               controller_task: FakeControllerTask,
               jira_connector: FakeJiraConnector,
               gitlab_reader: FakeReviewGitLabReader,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert %{"state" => "READY_FOR_REVIEW", "last_error" => nil} =
             Store.one!(store, "SELECT state, last_error FROM runs WHERE run_id = 'review-push-run'")

    assert_received {:push_exact, "cgable/PPL-123-factory-work", ^candidate}

    assert Store.one!(store, "SELECT status, reply_phase FROM mr_feedback_notes WHERE feedback_key = ?", [feedback.feedback_key]) ==
             %{"status" => "PENDING", "reply_phase" => 1}
  end

  test "a clear review edit resumes the existing writer without restarting planning", %{context: context, store: store, root: root} do
    candidate = String.duplicate("a", 40)
    writer_path = Path.join(root, "review-writer")
    File.mkdir_p!(writer_path)
    Process.put(:review_note_body, "@Symphony please simplify the switch")

    contract = Contract.bind("PPL-123", 1, "# Contract\n\n## Acceptance Criteria\n- AC-1: works")
    snapshot = authorized_snapshot(contract, ["ai-review", "repo-grail"]) |> Map.put("status", "In Dev")
    Process.put(:factory_controller_response, intake_response(snapshot))
    Process.put(:factory_jira_issue, snapshot)

    factory =
      context.factory
      |> Map.put(:task_transport, "desktop_broker")
      |> Map.put(:review_feedback, %{"enabled" => true, "allowed_author_ids" => [12], "bot_author_id" => 99})

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "review-admit-run",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "READY_FOR_REVIEW",
               repo_key: "grail",
               repo_path: factory.repositories["grail"]["path"],
               base_branch: "master",
               branch: "cgable/PPL-123-factory-work",
               worktree: writer_path,
               candidate_sha: candidate,
               mr_iid: 123,
               mr_url: "https://gitlab.example/grailbio/grail/-/merge_requests/123",
               snapshot_json: Jason.encode!(snapshot),
               contract_markdown: contract.markdown,
               contract_sha256: contract.sha256,
               spec_revision: 1,
               factory_owned: false
             })

    assert {:ok, writer} =
             TaskLedger.register(store, %{
               task_key: "review-admit-run:feature-writer",
               run_id: run["run_id"],
               stage: "WRITING",
               role: "feature-writer",
               status: "COMPLETE",
               model_provider: "codex",
               model_class: "test",
               model: "gpt-test",
               reasoning_effort: "medium",
               routing_reason: "test",
               codex_project_id: "project-grail",
               thread_id: "existing-writer-thread",
               workspace: writer_path,
               workspace_sha: candidate,
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _updated} = TaskLedger.update(store, writer["task_key"], %{turn_id: "existing-writer-turn"})

    note = %{"id" => 51, "body" => "@Symphony please simplify the switch", "updated_at" => "2026-09-30T10:00:00Z", "author" => %{"id" => 12}}
    discussion = %{"id" => "discussion-1", "notes" => [note]}
    route = Map.put(factory.repositories["grail"], "repo_key", "grail")
    mr = %{"project" => route["gitlab_project"], "iid" => 123, "web_url" => run["mr_url"], "source_branch" => run["branch"], "sha" => candidate, "state" => "opened"}
    {:ok, feedback} = MrFeedback.candidate(run, route, snapshot, mr, discussion, note, [12], 99)
    assert {:ok, :recorded} = MrFeedbackLedger.record_candidate(store, feedback)
    request_key = "review-admit-run:feedback-classification"
    Control.initialize(store, %{scope: factory.scope, dispatcher_id: factory.dispatcher_id})
    Control.record_controller_task(store, %{scope: factory.scope}, "controller-thread", "classified-turn", %{})

    assert {:ok, _request} =
             DesktopRequest.enqueue(store, %{
               request_key: request_key,
               target_kind: "CONTROLLER",
               target_key: factory.scope,
               action: "FOLLOWUP",
               existing_thread_id: "controller-thread",
               codex_project_id: "projectless",
               model: "gpt-test",
               reasoning_effort: "medium",
               title: "Classify review feedback",
               prompt: "Classify the requested edit",
               cwd: root
             })

    Store.query!(store, "UPDATE desktop_requests SET status = 'SUCCEEDED' WHERE request_key = ?", [request_key])
    Store.query!(store, "UPDATE mr_feedback_notes SET status = 'CHANGE_REQUEST', request_key = ? WHERE feedback_key = ?", [request_key, feedback.feedback_key])

    assert {:ok, _result} =
             Scheduler.tick(%{context | factory: factory},
               controller_task: FakeControllerTask,
               jira_connector: FakeJiraConnector,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Store.one!(store, "SELECT state FROM runs WHERE run_id = 'review-admit-run'")["state"] == "REVIEW_WRITING"

    assert Store.one!(store, "SELECT status, thread_id FROM factory_tasks WHERE task_key = ?", [writer["task_key"]]) ==
             %{"status" => "RETRY_PENDING", "thread_id" => "existing-writer-thread"}

    assert Store.one!(store, "SELECT status FROM mr_feedback_notes WHERE feedback_key = ?", [feedback.feedback_key])["status"] == "REWORKING"

    assert {:ok, %{launches: [_launch]}} =
             Scheduler.tick(%{context | factory: factory},
               controller_task: FakeControllerTask,
               jira_connector: FakeJiraConnector,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert_received {:stage_launch, "review-admit-run", ^writer_path, writer_prompt, writer_opts}
    assert writer_prompt =~ "REVIEW FEEDBACK BATCH"
    assert writer_prompt =~ "please simplify the switch"
    assert writer_opts[:task_key] == writer["task_key"]

    writer_output = Jason.encode!(%{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil})
    assert {:ok, _task} = TaskLedger.update(store, writer["task_key"], %{status: "COMPLETE", output_json: writer_output})

    assert {:ok, _result} =
             Scheduler.tick(%{context | factory: factory},
               controller_task: FakeControllerTask,
               jira_connector: FakeJiraConnector,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert %{"state" => "VERIFYING", "verifier_round" => 1} =
             Store.one!(store, "SELECT state, verifier_round FROM runs WHERE run_id = 'review-admit-run'")

    assert {:ok, %{launches: [_launch]}} =
             Scheduler.tick(%{context | factory: factory},
               controller_task: FakeControllerTask,
               jira_connector: FakeJiraConnector,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert_received {:stage_launch, "review-admit-run", _, verifier_prompt, verifier_opts}
    assert verifier_prompt =~ "REVIEW FEEDBACK BATCH"
    assert verifier_opts[:role] == "change-verifier"

    verifier_path = Path.join(root, "review-verifier")
    File.mkdir_p!(verifier_path)

    assert {:ok, _task} =
             TaskLedger.update(store, "review-admit-run:change-verifier:1", %{
               status: "COMPLETE",
               workspace: verifier_path,
               workspace_sha: candidate,
               output_json: Jason.encode!(%{"status" => "PASS", "candidate_sha" => candidate, "findings" => [], "checks" => []})
             })

    assert {:ok, _result} =
             Scheduler.tick(%{context | factory: factory},
               controller_task: FakeControllerTask,
               jira_connector: FakeJiraConnector,
               gitlab_reader: FakeReviewGitLabReader,
               feedback_consumer: FakeReviewConsumer,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Store.one!(store, "SELECT state FROM runs WHERE run_id = 'review-admit-run'")["state"] == "REVIEW_PUSHING"
  end

  test "registers and launches an assignee-wide specification task", %{context: context, store: store} do
    snapshot = snapshot(["spec-needed", "repo-grail"])

    Process.put(:factory_controller_response, %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => [snapshot]
    })

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert [%{task_key: task_key, pid: pid}] = result.launches
    assert task_key =~ ":specification-author"
    assert_receive {:controller_prompt, prompt}
    assert prompt =~ "assignee = currentUser()"
    assert_received {:controller_options, intake_opts}
    assert intake_opts[:model_role] == "orchestrator-intake"
    assert_receive {:stage_launch, run_id, _workspace, stage_prompt, stage_opts}
    assert stage_prompt =~ "specify-work"
    assert stage_opts[:role] == "specification-author"
    assert stage_opts[:project_id] == "project-grail"
    assert stage_opts[:thread_name] == "PPL-123 · Specification Author"

    assert {:ok, run} = RunLedger.get(store, run_id)
    assert run["kind"] == "SPECIFICATION"
    assert run["state"] == "SPEC_DRAFTING"
    assert run["workspace_state"] == "MATERIALIZED"
    assert File.dir?(run["worktree"])
    assert {:ok, %{snapshots: [^snapshot]}} = IntakeLedger.get(store, context.factory.scope)
    Process.exit(pid, :kill)
  end

  test "sweeps one freshly authorized terminal worktree when capacity is available", %{context: context} do
    candidates = [
      %{"run_id" => "old-run-1", "issue_key" => "PPL-200", "repo_key" => "grail", "state" => "DELIVERED"},
      %{"run_id" => "old-run-2", "issue_key" => "PPL-201", "repo_key" => "grail", "state" => "DELIVERED"}
    ]

    Process.put(:factory_cleanup_candidates, candidates)

    Process.put(:factory_controller_responses, [
      %{"status" => "PASS", "issue_key" => "QUEUE", "snapshot_json" => []},
      %{
        "status" => "PASS",
        "candidates" => [%{"run_id" => "old-run-1", "issue_key" => "PPL-200", "jira_status" => "DONE", "mr_state" => "merged"}]
      }
    ])

    factory =
      Map.put(context.factory, :cleanup, %{
        "enabled" => true,
        "allowed_run_states" => ["DELIVERED"]
      })

    assert {:ok, _result} =
             Scheduler.tick(%{context | factory: factory},
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert_received {:cleanup_candidates_requested, "grail"}
    assert_received {:controller_prompt, intake_prompt}
    assert intake_prompt =~ "assignee = currentUser()"
    assert_received {:controller_prompt, cleanup_prompt}
    assert cleanup_prompt =~ "old-run-1"
    assert cleanup_prompt =~ "PPL-200"
    assert_received {:cleanup_authorized, "old-run-1", "DONE", "merged"}
    assert_received {:cleanup_applied, "old-run-1"}
    refute_received {:cleanup_authorized, "old-run-2", _, _}
    refute_received {:cleanup_applied, "old-run-2"}
  end

  test "native Jira intake preserves the exact issue description instead of a controller paraphrase", %{
    context: context,
    store: store
  } do
    exact =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("description", "## Ticket Delivery Contract\n\n**Spec revision:** 1\n")
      |> Map.put("status", %{"name" => "To Do"})
      |> Map.put("project", %{"key" => "PPL"})

    Process.put(:factory_jira_search, %{"issues" => [%{"key" => exact["key"]}], "total" => 1})
    Process.put(:factory_jira_issue, exact)
    Process.put(:factory_controller_response, intake_response(%{exact | "description" => "Spec revision: 1"}))

    native_context =
      Map.update!(context, :factory, fn factory ->
        factory |> Map.put(:task_transport, "desktop_broker") |> Map.put(:maximum_specifiers, 0)
      end)

    assert {:ok, %{launches: []}} = tick(native_context)
    assert_receive {:jira_search_jql, jql}
    assert jql =~ "assignee = currentUser()"

    assert {:ok, %{snapshots: [%{"description" => description}]}} =
             IntakeLedger.get(store, context.factory.scope)

    assert description == exact["description"]
  end

  test "an unchanged failed specification does not launch again until Jira input changes", %{
    context: context,
    store: store
  } do
    original =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("assignee", %{"account_id" => "stable-user", "display_name" => "Example"})

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "failed-specification",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(original)
             })

    Process.put(:factory_controller_response, intake_response(original))
    assert {:ok, %{launches: []}} = tick(context)

    timestamp_only = %{original | "updated" => "2026-09-22T00:00:00Z"}
    Process.put(:factory_controller_response, intake_response(timestamp_only))
    assert {:ok, %{launches: []}} = tick(context)

    enriched_assignee =
      Map.put(timestamp_only, "assignee", %{
        "account_id" => "stable-user",
        "display_name" => "Example",
        "email" => "example@example.test",
        "avatar_url" => "https://example.test/avatar"
      })

    Process.put(:factory_controller_response, intake_response(enriched_assignee))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(store, "failed-specification")

    factory_comment =
      enriched_assignee
      |> Map.put("comments", [%{"id" => "10", "text" => "AI factory blocked: malformed output"}])
      |> Map.put("labels", ["spec-needed", "repo-grail", "ai-blocked"])

    Process.put(:factory_controller_response, intake_response(factory_comment))
    assert {:ok, %{launches: []}} = tick(context)

    revised = %{factory_comment | "description" => "Do the work with explicit compatibility criteria"}
    Process.put(:factory_controller_response, intake_response(revised))
    assert {:ok, %{launches: [launch]}} = tick(context)
    assert [%{"run_id" => "failed-specification"}] = RunLedger.list(store)
    assert launch.task_key == "failed-specification:specification-author"
    Process.exit(launch.pid, :kill)
  end

  test "a changed In Dev failed delivery is recovered by exact issue lookup without duplicate chats", %{
    context: context,
    store: store
  } do
    old = snapshot(["ai-running", "repo-grail"]) |> Map.put("status", "In Dev")
    revised = Map.put(old, "description", "Do the work with a revised acceptance criterion")

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "failed-delivery",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "FAILED",
               spec_revision: 1,
               contract_sha256: String.duplicate("a", 64),
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(old),
               failure_code: "acceptance_criteria_conflict"
             })

    empty_queue = %{"status" => "PASS", "issue_key" => "QUEUE", "snapshot_json" => "[]"}
    assert {:ok, failed_before} = RunLedger.get(store, "failed-delivery")
    assert ContractChat.changed?(failed_before, revised)
    Process.put(:factory_controller_responses, [empty_queue, intake_response(revised)])

    assert {:ok, result} = tick(context)
    assert_receive {:controller_prompt, queue_prompt}
    assert_receive {:controller_prompt, exact_prompt}
    assert length(result.launches) == 1
    [launch] = result.launches
    assert queue_prompt =~ "status IN"
    assert exact_prompt =~ "key IN"
    assert launch.task_key =~ ":contract-update"
    assert_receive {:stage_launch, _run_id, _workspace, stage_prompt, stage_opts}
    assert stage_prompt =~ "visible contract-update author"
    assert stage_opts[:thread_name] == "PPL-123 · Contract Update"

    assert [failed] = Enum.filter(RunLedger.list(store), &(&1["run_id"] == "failed-delivery"))
    assert [recovery] = Enum.reject(RunLedger.list(store), &(&1["run_id"] == "failed-delivery"))
    assert failed["run_id"] == "failed-delivery"
    assert failed["state"] == "FAILED"
    assert recovery["state"] == "CONTRACT_DISCUSSING"
    assert recovery["parent_run_id"] == failed["run_id"]

    Process.put(:factory_controller_responses, [empty_queue, intake_response(revised)])
    assert {:ok, %{launches: retries}} = tick(context)
    assert Enum.all?(retries, &(&1.task_key == launch.task_key))
    assert length(RunLedger.list(store)) == 2
    Process.exit(launch.pid, :kill)
    Enum.each(retries, &Process.exit(&1.pid, :kill))
  end

  test "future native contract discussions use the Project without a worktree while existing chats keep their checkout", %{
    context: context,
    store: store,
    root: root
  } do
    old = snapshot(["ai-running", "repo-grail"]) |> Map.put("status", "In Dev")
    revised = Map.put(old, "description", "Clarify the delivery acceptance criterion")

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "failed-delivery",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "FAILED",
               spec_revision: 1,
               contract_sha256: String.duplicate("a", 64),
               repo_key: "grail",
               repo_path: root,
               base_branch: "master",
               snapshot_json: Jason.encode!(old)
             })

    native_context = %{context | factory: Map.put(context.factory, :task_transport, "desktop_broker")}
    empty_queue = %{"status" => "PASS", "issue_key" => "QUEUE", "snapshot_json" => "[]"}
    Process.put(:factory_controller_responses, [empty_queue, intake_response(revised)])

    assert {:ok, %{launches: [first]}} = tick(native_context)
    assert_receive {:stage_launch, run_id, ^root, _prompt, first_opts}
    assert first_opts[:workspace_mode] == "CODEX_PROJECT_LOCAL"
    assert first_opts[:expected_sha] == nil
    assert first_opts[:project_id] == "project-grail"

    checkout = Path.join(root, "existing-contract-chat")
    File.mkdir_p!(checkout)
    sha = String.duplicate("b", 40)

    assert {:ok, _task} =
             TaskLedger.update(store, first.task_key, %{
               status: "RETRY_PENDING",
               workspace: checkout,
               workspace_sha: sha
             })

    Process.put(:factory_controller_responses, [empty_queue, intake_response(revised)])
    assert {:ok, %{launches: [continued]}} = tick(native_context)
    assert_receive {:stage_launch, ^run_id, ^checkout, _prompt, continued_opts}
    assert continued.task_key == first.task_key
    assert continued_opts[:workspace_mode] == "CODEX_NATIVE"
    assert continued_opts[:expected_sha] == sha
    assert length(RunLedger.list(store)) == 2

    Process.exit(first.pid, :kill)
    Process.exit(continued.pid, :kill)
  end

  test "a completed specification author remains consumable after the base branch advances", %{
    context: context,
    store: store
  } do
    snapshot =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("assignee", %{"account_id" => "stable-user", "display_name" => "Example"})
      |> Map.put("description", "## Ticket Delivery Contract\n\n**Spec revision:** 1\n")

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [author]}} = tick(context)

    complete_task(store, author.task_key, %{
      "status" => "DRAFTED",
      "contract_markdown" => "## Ticket Delivery Contract\n\n**Spec revision:** 2\n\n## Manual Validation\n- Required: no",
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    })

    Process.exit(author.pid, :kill)
    Process.put(:factory_base_sha, String.duplicate("c", 40))

    enriched =
      Map.put(snapshot, "assignee", %{
        "account_id" => "stable-user",
        "display_name" => "Example",
        "email" => "example@example.test",
        "avatar_url" => "https://example.test/avatar"
      })

    Process.put(:factory_controller_response, intake_response(enriched))

    assert {:ok, _result} = tick(context)
    [run] = RunLedger.list(store)
    assert run["state"] == "SPEC_WRITING"
    assert run["spec_revision"] == 2
  end

  test "a specification author carrying forward the prior revision is bound to the next revision", %{
    context: context,
    store: store
  } do
    snapshot =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("description", "## Ticket Delivery Contract\n\n**Spec revision:** 5\n")

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [author]}} = tick(context)
    assert_receive {:stage_launch, _run_id, _checkout, prompt, _opts}
    assert prompt =~ "Target specification revision: 6"

    complete_task(store, author.task_key, %{
      "status" => "DRAFTED",
      "contract_markdown" => "## Ticket Delivery Contract\n\n**Spec revision:** 5\n\n## Manual Validation\n- Required: no",
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    })

    Process.exit(author.pid, :kill)
    assert {:ok, _result} = tick(context)
    [run] = RunLedger.list(store)
    assert run["state"] == "SPEC_WRITING"
    assert run["spec_revision"] == 6
    assert Contract.declared_revision(run["contract_markdown"]) == {:ok, 6}
  end

  test "a Jira revision change during authoring relaunches the same task with a new target", %{
    context: context,
    store: store
  } do
    original =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("description", "## Ticket Delivery Contract\n\n**Spec revision:** 5\n")

    Process.put(:factory_controller_response, intake_response(original))
    assert {:ok, %{launches: [author]}} = tick(context)
    Process.exit(author.pid, :kill)

    complete_task(store, author.task_key, %{
      "status" => "DRAFTED",
      "contract_markdown" => "## Ticket Delivery Contract\n\n**Spec revision:** 6\n\n## Manual Validation\n- Required: no",
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    })

    revised = Map.put(original, "description", "## Ticket Delivery Contract\n\n**Spec revision:** 6\n")
    Process.put(:factory_controller_response, intake_response(revised))
    assert {:ok, %{launches: [relaunched]}} = tick(context)
    assert relaunched.task_key == author.task_key
    assert_receive {:stage_launch, _run_id, _checkout, _old_prompt, _opts}
    assert_receive {:stage_launch, _run_id, _checkout, new_prompt, _opts}
    assert new_prompt =~ "Target specification revision: 7"

    [run] = RunLedger.list(store)
    assert run["state"] == "SPEC_DRAFTING"
    assert run["spec_revision"] == 7
    assert run["contract_markdown"] == nil
    Process.exit(relaunched.pid, :kill)
  end

  test "a changed Jira specification reruns the same author task before accepting its draft", %{
    context: context,
    store: store
  } do
    original = snapshot(["spec-needed", "repo-grail"])
    Process.put(:factory_controller_response, intake_response(original))
    assert {:ok, %{launches: [first]}} = tick(context)
    assert_receive {:stage_launch, run_id, checkout, _prompt, opts}
    task_key = opts[:task_key]
    assert {:ok, _task} = TaskLedger.update(store, task_key, %{thread_id: "existing-thread"})

    complete_task(store, task_key, %{
      "status" => "DRAFTED",
      "contract_markdown" => "## Ticket Delivery Contract\n\n## Manual Validation\n- Required: no",
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    })

    Process.exit(first.pid, :kill)
    revised = Map.put(original, "description", "Do the revised work")
    Process.put(:factory_controller_response, intake_response(revised))
    assert {:ok, %{launches: [second]}} = tick(context)
    assert_receive {:stage_launch, ^run_id, ^checkout, revised_prompt, revised_opts}
    assert revised_opts[:task_key] == task_key
    assert revised_prompt =~ "Do the revised work"
    assert {:ok, %{"state" => "SPEC_DRAFTING", "contract_markdown" => nil}} = RunLedger.get(store, run_id)
    assert length(RunLedger.list(store)) == 1
    Process.exit(second.pid, :kill)
  end

  test "one local retry request permits a failed specification to relaunch once without Jira edits", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    Control.initialize(store, %{scope: context.factory.scope, dispatcher_id: context.factory.dispatcher_id})

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "failed-specification",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(snapshot)
             })

    assert {:ok, %{run_id: "failed-specification"}} =
             RunLedger.request_specification_retry(store, "PPL-123", context.factory.scope)

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [launch]}} = tick(context)
    refute RunLedger.specification_retry_pending?(store, "failed-specification")
    Process.exit(launch.pid, :kill)

    assert [%{"run_id" => "failed-specification"}] = RunLedger.list(store)
    RunLedger.update(store, "failed-specification", %{state: "FAILED"})
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
  end

  test "a local retry after switching to native tasks starts one new run instead of reviving an app-server task", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    Control.initialize(store, %{scope: context.factory.scope, dispatcher_id: context.factory.dispatcher_id})

    assert {:ok, _old_run} =
             RunLedger.register(store, %{
               run_id: "old-app-server-run",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               runtime: "codex-app-server",
               factory_owned: true,
               snapshot_json: Jason.encode!(snapshot)
             })

    assert {:ok, _old_task} =
             TaskLedger.register(store, %{
               task_key: "old-app-server-run:specification-author",
               run_id: "old-app-server-run",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "FAILED",
               model_provider: "codex",
               model_class: "test",
               model: "gpt-test",
               reasoning_effort: "medium",
               routing_reason: "test",
               codex_project_id: "project-grail",
               thread_id: "old-app-server-thread",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, %{run_id: "old-app-server-run"}} =
             RunLedger.request_specification_retry(store, "PPL-123", context.factory.scope)

    native_context = %{context | factory: Map.put(context.factory, :task_transport, "desktop_broker")}
    Process.put(:factory_controller_response, intake_response(snapshot))

    assert {:ok, %{launches: [launch]}} = tick(native_context)
    assert launch.task_key != "old-app-server-run:specification-author"

    assert {:ok, %{"runtime" => "codex-desktop-broker", "factory_owned" => 0}} =
             RunLedger.get(store, String.replace_suffix(launch.task_key, ":specification-author", ""))

    assert {:ok, %{"status" => "FAILED", "thread_id" => "old-app-server-thread"}} =
             TaskLedger.get(store, "old-app-server-run:specification-author")

    refute RunLedger.specification_retry_pending?(store, "old-app-server-run")
    Process.exit(launch.pid, :kill)
  end

  test "native cutover leaves an unchanged failed ticket alone until Jira input changes", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail"])

    assert {:ok, _old_run} =
             RunLedger.register(store, %{
               run_id: "old-app-server-run",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               runtime: "codex-app-server",
               factory_owned: true,
               snapshot_json: Jason.encode!(snapshot)
             })

    native_context = %{context | factory: Map.put(context.factory, :task_transport, "desktop_broker")}
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(native_context)
    assert [%{"run_id" => "old-app-server-run"}] = RunLedger.list(store)

    revised = %{snapshot | "description" => "Revised testable delivery contract"}
    Process.put(:factory_controller_response, intake_response(revised))
    assert {:ok, %{launches: [launch]}} = tick(native_context)
    assert launch.task_key != "old-app-server-run:specification-author"
    assert length(RunLedger.list(store)) == 2
    Process.exit(launch.pid, :kill)
  end

  test "retrying a failed specification resumes its existing task and checkout", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail", "ai-blocked"])
    checkout = Path.join(context.workspace_root, "retained-specification")
    File.mkdir_p!(checkout)
    Control.initialize(store, %{scope: context.factory.scope, dispatcher_id: context.factory.dispatcher_id})

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "failed-specification",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: checkout,
               workspace_state: "MATERIALIZED",
               snapshot_json: Jason.encode!(snapshot)
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "failed-specification:specification-author",
               run_id: "failed-specification",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "FAILED",
               model_provider: "codex",
               model_class: "test",
               model: "gpt-test",
               reasoning_effort: "medium",
               routing_reason: "test",
               codex_project_id: "project-grail",
               thread_id: "existing-thread",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, %{run_id: "failed-specification"}} =
             RunLedger.request_specification_retry(store, "PPL-123", context.factory.scope)

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [launch]}} = tick(context)
    assert_receive {:stage_launch, "failed-specification", ^checkout, _prompt, opts}
    assert opts[:task_key] == "failed-specification:specification-author"
    assert length(RunLedger.list(store)) == 1

    assert {:ok, %{"thread_id" => "existing-thread"}} =
             TaskLedger.get(store, "failed-specification:specification-author")

    Process.exit(launch.pid, :kill)
  end

  test "a failed author task keeps its checkout for the same-task retry", %{context: context, store: store} do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    checkout = Path.join(context.workspace_root, "author-failure-checkout")
    File.mkdir_p!(checkout)

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "author-failure",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_DRAFTING",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: checkout,
               snapshot_json: Jason.encode!(snapshot)
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "author-failure:specification-author",
               run_id: "author-failure",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "FAILED",
               model_provider: "codex",
               model_class: "test",
               model: "gpt-test",
               reasoning_effort: "medium",
               routing_reason: "test",
               codex_project_id: "project-grail",
               thread_id: "existing-thread",
               prompt_sha256: String.duplicate("a", 64)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    refute_received {:removed_detached, ^checkout}
    assert {:ok, %{"state" => "FAILED", "worktree" => ^checkout}} = RunLedger.get(store, "author-failure")
  end

  test "a retry with a missing bound author checkout blocks without creating another task", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail", "ai-blocked"])
    missing_checkout = Path.join(context.workspace_root, "missing-author-checkout")
    Control.initialize(store, %{scope: context.factory.scope, dispatcher_id: context.factory.dispatcher_id})

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "missing-author",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: missing_checkout,
               snapshot_json: Jason.encode!(snapshot)
             })

    assert {:ok, _task} =
             TaskLedger.register(store, %{
               task_key: "missing-author:specification-author",
               run_id: "missing-author",
               stage: "SPEC_DRAFTING",
               role: "specification-author",
               status: "FAILED",
               model_provider: "codex",
               model_class: "test",
               model: "gpt-test",
               reasoning_effort: "medium",
               routing_reason: "test",
               codex_project_id: "project-grail",
               thread_id: "existing-thread",
               prompt_sha256: String.duplicate("a", 64)
             })

    assert {:ok, _retry} = RunLedger.request_specification_retry(store, "PPL-123", context.factory.scope)
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(store, "missing-author")
    assert [%{"task_key" => "missing-author:specification-author"}] = TaskLedger.list_for_run(store, "missing-author")
    refute_received {:stage_launch, _, _, _, _}
  end

  test "a changed repository route holds only that specification and leaves other intake progressing", %{
    context: context,
    store: store
  } do
    original = snapshot(["spec-needed", "repo-grail"])

    assert {:ok, _run} =
             RunLedger.register(store, %{
               run_id: "failed-specification",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "FAILED",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(original)
             })

    blackburn = %{
      "path" => Path.join(context.workspace_root, "blackburn"),
      "base_branch" => "main",
      "codex_project_id" => "project-blackburn",
      "gitlab_project" => "grailbio/blackburn",
      "route_labels" => ["repo-blackburn"]
    }

    File.mkdir_p!(blackburn["path"])
    context = put_in(context.factory.repositories["blackburn"], blackburn)

    rerouted =
      original
      |> Map.put("labels", ["spec-needed", "repo-blackburn", "ai-blocked"])
      |> Map.put("description", "Revised work for another repository")

    other =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("key", "PPL-124")
      |> Map.put("id", "101")

    Process.put(:factory_controller_response, %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([rerouted, other])
    })

    assert {:ok, %{routing_required: ["PPL-123"], launches: [launch]}} = tick(context)
    assert launch.task_key =~ ":specification-author"
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(store, "failed-specification")
    assert Enum.count(RunLedger.list(store), &(&1["issue_key"] == "PPL-123")) == 1
    Process.exit(launch.pid, :kill)
  end

  test "an independent critic remains consumable when master advances during its task", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail"])

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "critic-run",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_REVIEW",
               spec_revision: 1,
               verifier_round: 1,
               contract_markdown: "## Ticket Delivery Contract\n\n## Manual Validation\n- Required: no",
               contract_sha256: String.duplicate("a", 64),
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(snapshot)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [critic]}} = tick(context)
    complete_task(store, critic.task_key, %{"status" => "PASS", "findings" => [], "required_questions" => []})
    Process.exit(critic.pid, :kill)

    Process.put(:factory_base_sha, String.duplicate("c", 40))
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "SPEC_READY_WRITE"}} = RunLedger.get(store, "critic-run")
  end

  test "a changed Jira specification blocks a completed critic verdict for the previous input", %{
    context: context,
    store: store
  } do
    original = snapshot(["spec-needed", "repo-grail"])

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "critic-run",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_REVIEW",
               spec_revision: 1,
               verifier_round: 1,
               contract_markdown: "## Ticket Delivery Contract\n\n## Manual Validation\n- Required: no",
               contract_sha256: String.duplicate("a", 64),
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(original)
             })

    Process.put(:factory_controller_response, intake_response(original))
    assert {:ok, %{launches: [critic]}} = tick(context)
    complete_task(store, critic.task_key, %{"status" => "PASS", "findings" => [], "required_questions" => []})
    Process.exit(critic.pid, :kill)

    revised = Map.put(original, "description", "Changed acceptance criteria")
    Process.put(:factory_controller_response, intake_response(revised))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED"}} = RunLedger.get(store, "critic-run")
    assert {:ok, %{"status" => "STALE"}} = TaskLedger.get(store, critic.task_key)
  end

  test "critic repair advances past the already-written draft revision", %{context: context, store: store} do
    contract =
      Contract.bind(
        "PPL-123",
        6,
        "## Ticket Delivery Contract\n\n**Spec revision:** 6\n\n## Manual Validation\n- Required: no"
      )

    snapshot =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("description", "## Ticket Delivery Contract\n\n**Spec revision:** 5")
      |> Map.put("comments", [%{"id" => "draft-6", "text" => Contract.draft_comment(contract)}])

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "critic-repair",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_REVIEW",
               spec_revision: 6,
               verifier_round: 1,
               contract_markdown: contract.markdown,
               contract_sha256: contract.sha256,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(snapshot)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [critic]}} = tick(context)
    complete_task(store, critic.task_key, %{"status" => "REPAIR", "findings" => ["Clarify boundary"], "required_questions" => []})
    Process.exit(critic.pid, :kill)

    assert {:ok, _result} = tick(context)
    assert {:ok, revised} = RunLedger.get(store, run["run_id"])
    assert revised["state"] == "SPEC_DRAFTING"
    assert revised["spec_revision"] == 7
    assert revised["attempt"] == 2
    assert revised["contract_markdown"] == nil
    assert revised["contract_sha256"] == nil
    assert revised["repair_findings_json"] == Jason.encode!(["Clarify boundary"])
  end

  test "a failed specification write releases only its clean factory-owned detached checkout", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    path = Path.join(context.workspace_root, "failed-specification-checkout")
    File.mkdir_p!(path)

    assert {:ok, _registered} =
             RunLedger.register(store, %{
               run_id: "failed-write",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_WRITING",
               spec_revision: 1,
               contract_markdown: "## Ticket Delivery Contract\n\n## Manual Validation\n- Required: no",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: path,
               snapshot_json: Jason.encode!(snapshot)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, _result} = tick(context)
    assert_received {:removed_detached, ^path}
    assert {:ok, failed} = RunLedger.get(store, "failed-write")
    assert failed["state"] == "FAILED"
    assert failed["worktree"] == nil

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
  end

  test "runs two-phase Jira spec write, independent critique, and exact human authorization", %{
    context: context,
    store: store
  } do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [author]}} = tick(context)

    markdown =
      "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"

    complete_task(store, author.task_key, %{
      "status" => "DRAFTED",
      "contract_markdown" => markdown,
      "questions" => [],
      "risk" => "low",
      "risk_signals" => [],
      "manual_validation_required" => false
    })

    Process.exit(author.pid, :kill)
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, _result} = tick(context)

    [run] = RunLedger.list(store)
    assert {:ok, %{"state" => "SPEC_WRITING"} = drafted} = RunLedger.get(store, run["run_id"])
    contract = Contract.bind("PPL-123", 1, markdown)
    assert drafted["contract_sha256"] == contract.sha256

    readback_snapshot = Map.put(snapshot, "comments", [%{"id" => "10", "text" => Contract.draft_comment(contract)}])

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      jira_write_response(["spec-needed", "repo-grail"], contract.marker),
      %{"status" => "PASS", "issue_key" => "PPL-123", "snapshot_json" => Jason.encode!(readback_snapshot)}
    ])

    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "SPEC_REVIEW"}} = RunLedger.get(store, run["run_id"])
    assert_received {:jira_write_options, write_opts}
    assert write_opts[:approval_policy] == "on-request"

    assert write_opts[:allowed_mcp_tool_approvals] == [
             %{
               server: "Jira",
               tool: "jira_add_comment",
               issue_key: "PPL-123",
               body_equals: Contract.draft_comment(contract)
             }
           ]

    assert write_opts[:required_tool_calls] == [
             %{server: "Jira", tool: "jira_add_comment"},
             %{server: "Jira", tool: "jira_get_issue"}
           ]

    Process.put(:factory_controller_response, intake_response(readback_snapshot))
    assert {:ok, %{launches: [critic]}} = tick(context)
    assert critic.task_key =~ "specification-critic"

    complete_task(store, critic.task_key, %{
      "status" => "PASS",
      "findings" => [],
      "required_questions" => []
    })

    Process.exit(critic.pid, :kill)
    Process.put(:factory_controller_response, intake_response(readback_snapshot))
    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "SPEC_READY_WRITE"}} = RunLedger.get(store, run["run_id"])

    Process.put(:factory_controller_responses, [
      intake_response(readback_snapshot),
      jira_write_response(["spec-needed", "repo-grail"], Contract.ready_marker(contract))
    ])

    assert {:ok, ready_result} = tick(context)
    assert Enum.any?(ready_result.events, &(&1.event == "HUMAN_CONFIRMATION_REQUIRED"))
    assert {:ok, %{"state" => "AWAITING_CONFIRMATION"}} = RunLedger.get(store, run["run_id"])
    assert_received {:jira_write_options, _ready_opts}

    confirmed_snapshot =
      Map.update!(readback_snapshot, "comments", fn comments ->
        comments ++ [%{"id" => "11", "text" => Contract.confirmation_marker(contract)}]
      end)

    Process.put(:factory_controller_responses, [
      intake_response(confirmed_snapshot),
      jira_write_response(["ai-ready", "repo-grail"], Contract.authorization_marker(contract, "11"))
    ])

    assert {:ok, authorized_result} = tick(context)
    assert Enum.any?(authorized_result.events, &(&1.event == "SPECIFICATION_AUTHORIZED"))
    assert_received {:jira_write_options, authorization_opts}

    assert authorization_opts[:allowed_mcp_tool_approvals] == [
             %{
               server: "Jira",
               tool: "jira_add_comment",
               issue_key: "PPL-123",
               body_equals: Contract.authorization_marker(contract, "11")
             },
             %{
               server: "Jira",
               tool: "jira_update_issue",
               issue_key: "PPL-123",
               labels_equals: ["ai-ready", "repo-grail"]
             }
           ]

    assert {:ok, authorized} = RunLedger.get(store, run["run_id"])
    assert authorized["state"] == "DELIVERED"
    assert authorized["confirmation_comment_id"] == "11"
  end

  test "a critic PASS automatically authorizes the exact contract without a human comment", %{
    context: context,
    store: store
  } do
    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no"
      )

    snapshot =
      snapshot(["spec-needed", "repo-grail"])
      |> Map.put("comments", [%{"id" => "10", "text" => Contract.draft_comment(contract)}])

    critic_key = "auto-spec:specification-critic:1"
    critic_output = Jason.encode!(%{"status" => "PASS", "findings" => [], "required_questions" => []})
    critic_prompt = Prompt.specification_critic(snapshot, contract.markdown, contract.sha256)
    prompt_sha = :crypto.hash(:sha256, critic_prompt) |> Base.encode16(case: :lower)

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "auto-spec",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "SPEC_READY_WRITE",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               verifier_round: 1,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(snapshot)
             })

    assert {:ok, _critic} =
             TaskLedger.register(store, %{
               task_key: critic_key,
               run_id: run["run_id"],
               stage: "SPEC_REVIEW",
               role: "specification-critic",
               status: "CONSUMED",
               model_provider: "codex",
               model_class: "test",
               model: "gpt-test",
               reasoning_effort: "high",
               routing_reason: "test",
               prompt_sha256: prompt_sha
             })

    assert {:ok, _critic} = TaskLedger.update(store, critic_key, %{output_json: critic_output})

    authorization =
      Contract.automatic_authorization_marker(contract, critic_key, Contract.digest(critic_output))

    authorized_snapshot =
      snapshot
      |> Map.put("labels", ["repo-grail", "ai-ready"])
      |> Map.update!("comments", &(&1 ++ [%{"id" => "11", "text" => authorization}]))

    auto_context =
      Map.update!(context, :factory, &Map.put(&1, :specification_authorization_mode, "auto_after_critic"))

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{"status" => "PASS", "issue_key" => "PPL-123", "snapshot_json" => Jason.encode!(snapshot)},
      jira_write_response(["ai-ready", "repo-grail"], authorization),
      %{"status" => "PASS", "issue_key" => "PPL-123", "snapshot_json" => Jason.encode!(authorized_snapshot)}
    ])

    assert {:ok, result} = tick(auto_context)
    assert Enum.any?(result.events, &(&1.event == "SPECIFICATION_AUTO_AUTHORIZED"))
    assert {:ok, %{"state" => "DELIVERED", "confirmation_comment_id" => nil}} = RunLedger.get(store, run["run_id"])
    assert Contract.authorized?(authorized_snapshot, contract)
    refute Enum.any?(authorized_snapshot["comments"], &String.contains?(&1["text"], "AI FACTORY CONFIRM "))
  end

  test "an automatic Jira marker without its local independent critic proof cannot launch delivery", %{
    context: context,
    store: store
  } do
    contract = Contract.bind("PPL-123", 1, "## Manual Validation\n- Required: no")

    ready =
      snapshot(["ai-ready", "repo-grail"])
      |> Map.put("comments", [
        %{"id" => "1", "text" => Contract.draft_comment(contract)},
        %{
          "id" => "2",
          "text" =>
            Contract.automatic_authorization_marker(
              contract,
              "missing-run:specification-critic:1",
              String.duplicate("a", 64)
            )
        }
      ])

    Process.put(:factory_controller_response, intake_response(ready))
    assert {:ok, %{launches: [], events: events}} = tick(context)
    assert Enum.any?(events, &(&1.event == "AUTHORIZATION_REQUIRED"))
    assert RunLedger.list(store) == []
  end

  test "requires an exact authorization record before launching delivery", %{context: context, store: store} do
    contract =
      Contract.bind(
        "PPL-123",
        1,
        """
        ## Ticket Delivery Contract
        **Spec revision:** 1

        ### Problem and outcome
        Document extraction currently applies one judge-vote threshold to every request. This change lets each request select its threshold.

        ### In scope
        - Resolve the effective vote threshold per extraction request while preserving the configured default.

        ### Acceptance criteria
        - AC-1: Given a request-specific threshold, when extraction evaluates judge votes, then only that request uses the override.

        ### Shared decisions and dependencies
        - SD-1: The existing configured threshold remains the fallback when a request does not provide an override.

        ### Out of scope
        - Changing the global default threshold.

        ### Verification
        - Confirm request overrides affect only their own evaluation and omitted overrides preserve existing behavior.

        ## Manual Validation
        - Required: no
        - Reason: behavior is covered by deterministic tests.
        """
      )

    authorized =
      snapshot(["ai-ready", "repo-grail"])
      |> Map.put("comments", [
        %{"id" => "1", "text" => Contract.draft_comment(contract)},
        %{"id" => "2", "text" => Contract.specification_skill_authorization_marker(contract)}
      ])

    Process.put(:factory_controller_responses, [
      intake_response(authorized),
      jira_write_response(["ai-running", "repo-grail"], "ai-running")
    ])

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert result.launches == []
    assert_received {:jira_write_options, _label_write_opts}
    [delivery] = RunLedger.list(store)
    assert delivery["state"] == "WRITING"

    running = %{authorized | "labels" => ["ai-running", "repo-grail"]}
    Process.put(:factory_controller_response, intake_response(running))
    assert {:ok, result} = tick(context)
    assert [%{task_key: task_key, pid: pid}] = result.launches
    assert task_key =~ ":feature-writer"
    assert_receive {:stage_launch, run_id, _workspace, prompt, opts}
    assert prompt =~ "draft-feature-cycle"
    assert prompt =~ "Target five minutes"
    assert prompt =~ "up to ten"
    assert prompt =~ "Do not launch a separate planner"
    assert opts[:role] == "feature-writer"
    assert opts[:project_id] == "project-grail"
    assert opts[:thread_name] == "PPL-123 · Feature Writer"

    assert {:ok, run} = RunLedger.get(store, run_id)
    assert run["kind"] == "DELIVERY"
    assert run["state"] == "WRITING"
    assert run["contract_sha256"] == contract.sha256
    assert run["manual_validation_required"] == 0
    Process.exit(pid, :kill)
  end

  test "delivery routing carries only unique exact-contract specification risk", %{context: context, root: root} do
    contract = Contract.bind("PPL-123", 1, "## Manual Validation\n- Required: no")

    policy = %{
      "default_provider" => "codex",
      "providers" => %{"codex" => %{"balanced" => "balanced-test", "deep" => "deep-test"}},
      "roles" => %{
        "feature-writer" => %{"model_class" => "balanced", "reasoning_effort" => "high"},
        "feature-writer-high-risk" => %{"model_class" => "deep", "reasoning_effort" => "xhigh"}
      },
      "delivery_routing" => %{
        "default_role" => "feature-writer",
        "high_risk_role" => "feature-writer-high-risk",
        "high_risk_values" => ["high", "critical", "unknown"],
        "high_risk_signals" => ["security"],
        "unknown_risk_is_high" => true
      }
    }

    cases = [
      {"low", [%{risk: "low"}], "low", [], "feature-writer"},
      {"routine", [%{risk: "routine"}], "routine", [], "feature-writer"},
      {"medium", [%{risk: "medium"}], "medium", [], "feature-writer"},
      {"high", [%{risk: "high"}], "high", [], "feature-writer-high-risk"},
      {"critical", [%{risk: "critical"}], "critical", [], "feature-writer-high-risk"},
      {"signal", [%{risk: "low", risk_signals_json: ~s(["security"])}], "low", ["security"], "feature-writer-high-risk"},
      {"missing", [], "unknown", [], "feature-writer-high-risk"},
      {"invalid", [%{risk: "probably safe"}], "unknown", [], "feature-writer-high-risk"},
      {"invalid-signals", [%{risk: "low", risk_signals_json: "{}"}], "unknown", [], "feature-writer-high-risk"},
      {"invalid-signals-json", [%{risk: "low", risk_signals_json: "not json"}], "unknown", [], "feature-writer-high-risk"},
      {"invalid-signal-item", [%{risk: "low", risk_signals_json: "[1]"}], "unknown", [], "feature-writer-high-risk"},
      {"nil-risk", [%{risk: nil}], "unknown", [], "feature-writer-high-risk"},
      {"nil-signals", [%{risk: "low", risk_signals_json: nil}], "unknown", [], "feature-writer-high-risk"},
      {"wrong-digest", [%{risk: "low", contract_sha256: String.duplicate("f", 64)}], "unknown", [], "feature-writer-high-risk"},
      {"wrong-markdown", [%{risk: "low", contract_markdown: "Risk: low"}], "unknown", [], "feature-writer-high-risk"},
      {"wrong-revision", [%{risk: "low", spec_revision: 2}], "unknown", [], "feature-writer-high-risk"},
      {"unfinished", [%{risk: "low", state: "FAILED"}], "unknown", [], "feature-writer-high-risk"},
      {"wrong-issue", [%{risk: "low", issue_key: "PPL-456"}], "unknown", [], "feature-writer-high-risk"},
      {"duplicate", [%{risk: "low"}, %{risk: "low"}], "unknown", [], "feature-writer-high-risk"},
      {"conflicting", [%{risk: "low"}, %{risk: "critical"}], "unknown", [], "feature-writer-high-risk"}
    ]

    for {name, specifications, expected_risk, expected_signals, expected_role} <- cases do
      {:ok, store} = Store.start_link(database: Path.join(root, "risk-#{name}.sqlite"))
      local_context = %{context | store: store}

      try do
        for {overrides, index} <- Enum.with_index(specifications) do
          attrs = %{
            run_id: "spec-#{index}",
            issue_key: contract.issue_key,
            kind: "SPECIFICATION",
            state: "DELIVERED",
            spec_revision: contract.revision,
            contract_sha256: contract.sha256,
            contract_markdown: contract.markdown,
            risk_signals_json: "[]"
          }

          assert {:ok, _registered} = RunLedger.register(store, Map.merge(attrs, overrides))
        end

        ready =
          authorized_snapshot(contract, ["ai-ready", "repo-grail"])
          |> Map.put("description", "Risk: low")
          |> Map.put("risk", "low")
          |> Map.update!("comments", &(&1 ++ [%{"id" => "4", "text" => "Risk: low"}]))

        Process.put(:factory_controller_responses, [
          intake_response(ready),
          jira_write_response(["ai-running", "repo-grail"], "ai-running")
        ])

        assert {:ok, _result} = tick(local_context)
        delivery = Enum.find(RunLedger.list(store), &(&1["kind"] == "DELIVERY"))
        assert delivery["risk"] == expected_risk, name
        assert Jason.decode!(delivery["risk_signals_json"]) == expected_signals, name

        assert {:ok, route} =
                 ModelRouter.resolve(policy, "feature-writer",
                   risk: delivery["risk"],
                   risk_signals: Jason.decode!(delivery["risk_signals_json"])
                 )

        assert route.resolved_role == expected_role, name
      after
        GenServer.stop(store)
      end
    end
  end

  test "a newer unconfirmed contract blocks delivery despite the ai-ready label", %{context: context, store: store} do
    original = Contract.bind("PPL-123", 1, "## Manual Validation\n- Required: no")
    revised = Contract.bind("PPL-123", 2, "## Manual Validation\n- Required: no\n- Reason: changed scope")

    ticket =
      snapshot(["ai-ready", "repo-grail"])
      |> Map.put("comments", [
        %{"id" => "1", "text" => Contract.draft_comment(original)},
        %{"id" => "2", "text" => Contract.confirmation_marker(original)},
        %{"id" => "3", "text" => Contract.authorization_marker(original, "2")},
        %{"id" => "4", "text" => Contract.draft_comment(revised)}
      ])

    Process.put(:factory_controller_response, intake_response(ticket))

    assert {:ok, %{launches: [], events: events}} = tick(context)
    assert Enum.any?(events, &(&1.event == "AUTHORIZATION_REQUIRED"))
    refute Enum.any?(RunLedger.list(store), &(&1["kind"] == "DELIVERY"))
    refute_received {:stage_launch, _, _, _, _}
  end

  test "asks bound Jira questions and resumes only after matching human input", %{context: context, store: store} do
    snapshot = snapshot(["spec-needed", "repo-grail"])
    Process.put(:factory_controller_response, intake_response(snapshot))

    assert {:ok, %{launches: [launch]}} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    [run] = RunLedger.list(store)
    questions = ["Which compatibility behavior is required?"]
    assert_receive {:stage_launch, _initial_run_id, _initial_checkout, _initial_prompt, _initial_opts}

    TaskLedger.update(store, launch.task_key, %{
      status: "COMPLETE",
      output_json:
        Jason.encode!(%{
          "status" => "BLOCKED",
          "contract_markdown" => "",
          "questions" => questions,
          "risk" => "unknown",
          "risk_signals" => [],
          "manual_validation_required" => false
        })
    })

    digest = Contract.questions_digest(questions)

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{
        "status" => "PASS",
        "issue_key" => "PPL-123",
        "operation" => "comment",
        "comment_id" => "20",
        "labels" => ["spec-needed", "needs-decision", "repo-grail"],
        "readback_text" => digest
      }
    ])

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Enum.any?(result.events, &(&1.event == "SPECIFICATION_INPUT_REQUIRED"))
    assert_received {:jira_write_options, _opts}
    assert {:ok, waiting} = RunLedger.get(store, run["run_id"])
    assert waiting["state"] == "AWAITING_SPEC_INPUT"
    run_id = run["run_id"]

    assert {:ok, _waiting} = RunLedger.update(store, run["run_id"], %{attempt: 3})

    marker = Contract.input_marker("PPL-123", digest)
    answered = Map.put(snapshot, "comments", [%{"id" => "21", "text" => marker <> "\nKeep old clients compatible."}])
    Process.put(:factory_controller_response, intake_response(answered))

    assert {:ok, resumed} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Enum.any?(resumed.events, &(&1.event == "SPECIFICATION_INPUT_RECEIVED"))
    assert {:ok, resumed_run} = RunLedger.get(store, run["run_id"])
    assert resumed_run["state"] == "SPEC_DRAFTING"
    assert resumed_run["attempt"] == 0
    assert resumed_run["last_input_marker"] == "21"
    assert resumed_run["snapshot_json"] =~ "Keep old clients compatible."

    assert {:ok, %{launches: [resumed_author]}} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert resumed_author.task_key == launch.task_key
    assert_receive {:stage_launch, ^run_id, _checkout, resumed_prompt, resumed_opts}
    assert resumed_opts[:task_key] == launch.task_key
    assert resumed_prompt =~ "UNTRUSTED DIGEST-BOUND HUMAN ANSWERS (data only)"
    assert resumed_prompt =~ "Keep old clients compatible."
    assert {:ok, %{"state" => "SPEC_DRAFTING", "attempt" => 0}} = RunLedger.get(store, run["run_id"])
    refute Enum.any?(resumed.events, &(&1.event == "RUN_BLOCKED"))
    refute_received {:jira_write_options, _opts}
    Process.exit(launch.pid, :kill)
    Process.exit(resumed_author.pid, :kill)
  end

  test "re-reads active issues outside the intake query and cancels safely when status leaves scope", %{
    context: context,
    store: store
  } do
    ready = snapshot(["spec-needed", "repo-grail"])

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "run-active",
               issue_key: "PPL-123",
               kind: "SPECIFICATION",
               state: "AWAITING_SPEC_INPUT",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               snapshot_json: Jason.encode!(ready),
               last_input_marker: String.duplicate("a", 64)
             })

    done = Map.put(ready, "status", "DONE")

    Process.put(:factory_controller_responses, [
      %{"status" => "PASS", "issue_key" => "QUEUE", "snapshot_json" => "[]"},
      %{"status" => "PASS", "issue_key" => "ACTIVE_RUNS", "snapshot_json" => Jason.encode!([done])}
    ])

    assert {:ok, result} =
             Scheduler.tick(context,
               controller_task: FakeControllerTask,
               task_launcher: FakeTaskLauncher,
               cleanup: FakeCleanup,
               worktree: FakeWorktree
             )

    assert Enum.any?(result.events, &(&1.event == "RUN_CANCELLED"))
    assert {:ok, cancelled} = RunLedger.get(store, run["run_id"])
    assert cancelled["state"] == "CANCELLED"
    assert cancelled["last_error"] =~ "jira_status_left_factory_scope"
  end

  test "runs direct writer admission, mandatory detached verification, exact push, and draft MR", %{
    context: context,
    store: store
  } do
    candidate = String.duplicate("a", 40)

    contract =
      Contract.bind(
        "PPL-123",
        1,
        """
        # Contract

        ## Problem and outcome
        Extraction currently applies one judge-vote threshold to every request. This change lets each request choose its own threshold while preserving the configured default.

        ## In scope
        - Resolve the effective vote threshold per extraction request while preserving the configured default.
        - Carry the request threshold through synchronous extraction, asynchronous jobs, and replay.
        - Change deployment-wide defaults.

        ## Shared decisions and dependencies
        - SD-1: The existing configured threshold remains the fallback when a request does not provide an override.
        - SD-2: Keep unrelated deployment settings unchanged.

        ## Out of scope
        - Changing the global default threshold.

        ## Acceptance Criteria
        - AC-1: Given a request-specific threshold, when extraction evaluates judge votes, then only that request uses the override.
        - AC-2: When a request omits its threshold, then the configured default remains in effect.
        - AC-3: Replay accepts a request threshold without changing the global default.
        - AC-4: Invalid thresholds are rejected before work is queued.

        ## Manual Validation
        - Required: no
        - Reason: deterministic tests
        """
      )

    snapshot = authorized_snapshot(contract, ["ai-ready", "repo-grail"])
    running_snapshot = %{snapshot | "labels" => ["ai-running", "repo-grail"]}

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      jira_write_response(["ai-running", "repo-grail"], "ai-running")
    ])

    assert {:ok, _result} = tick(context)

    [run] = RunLedger.list(store)
    assert {:ok, %{"state" => "WRITING"}} = RunLedger.get(store, run["run_id"])

    assert_received {:jira_write_options, label_write_opts}

    assert label_write_opts[:allowed_mcp_tool_approvals] == [
             %{
               server: "Jira",
               tool: "jira_update_issue",
               issue_key: "PPL-123",
               labels_equals: ["ai-running", "repo-grail"]
             }
           ]

    assert label_write_opts[:required_tool_calls] == [
             %{server: "Jira", tool: "jira_update_issue"},
             %{server: "Jira", tool: "jira_get_issue"}
           ]

    assert {:ok, %{"state" => "WRITING", "branch" => "cgable/PPL-123-factory-work"}} =
             RunLedger.get(store, run["run_id"])

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, %{launches: [writer]}} = tick(context)

    complete_task(store, writer.task_key, %{
      "status" => "COMPLETE",
      "summary" => "implemented",
      "commit_sha" => candidate,
      "remaining_criteria" => [],
      "blockers" => [],
      "checks" => ["unit tests passed"]
    })

    Process.exit(writer.pid, :kill)

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "VERIFYING"}} = RunLedger.get(store, run["run_id"])
    refute_received {:push_exact, _branch, _sha}

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, %{launches: [verifier]}} = tick(context)
    assert verifier.task_key =~ "change-verifier"

    complete_task(store, verifier.task_key, %{
      "status" => "PASS",
      "candidate_sha" => candidate,
      "findings" => [],
      "checks" => ["all acceptance criteria passed"]
    })

    Process.exit(verifier.pid, :kill)

    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, _result} = tick(context)
    assert {:ok, %{"state" => "PUSHING"}} = RunLedger.get(store, run["run_id"])
    refute_received {:push_exact, _branch, _sha}

    mr_url = "https://gitlab.example/grailbio/grail/-/merge_requests/7"

    Process.put(:factory_controller_responses, [
      intake_response(running_snapshot),
      %{
        "status" => "PASS",
        "mr_url" => mr_url,
        "iid" => 7,
        "source_branch" => "cgable/PPL-123-factory-work",
        "target_branch" => "master",
        "sha" => candidate,
        "draft" => true,
        "reviewers_count" => 0,
        "assignee_id" => 11_599_766,
        "state" => "opened"
      },
      jira_write_response(["ai-review", "repo-grail"], mr_url)
    ])

    assert {:ok, final} = tick(context)
    run_id = run["run_id"]
    assert_received {:push_exact, "cgable/PPL-123-factory-work", ^candidate}
    assert_received {:hibernate, ^run_id}
    assert Enum.any?(final.events, &(&1.event == "READY_FOR_REVIEW"))
    assert Enum.any?(final.events, &(&1.event == "HIBERNATION_SKIPPED"))

    prompts =
      self()
      |> Process.info(:messages)
      |> elem(1)
      |> Enum.flat_map(fn
        {:controller_prompt, prompt} -> [prompt]
        _message -> []
      end)

    assert [mr_prompt] = Enum.filter(prompts, &String.contains?(&1, "Create or reuse exactly one reviewer-free"))
    [_, mr_body] = String.split(mr_prompt, "MR description:\n", parts: 2)
    assert mr_body =~ "## Summary"
    assert mr_body =~ "Extraction currently applies one judge-vote threshold to every request;"
    assert mr_body =~ "### Changes\n\n- Resolve the effective vote threshold per extraction request while preserving the configured default."
    assert mr_body =~ "### Design notes\n\n- SD-1: The existing configured threshold remains the fallback when a request does not provide an override."
    refute mr_body =~ "**Risk:** Request overrides could leak across concurrent extractions."
    assert mr_body =~ "**Out of scope:** Changing the global default threshold."
    assert mr_body =~ "## Test plan\n\n- AC-1: Given a request-specific threshold, when extraction evaluates judge votes, then only that request uses the override."
    assert mr_body =~ "- AC-2: When a request omits its threshold, then the configured default remains in effect."
    refute mr_body =~ "AC-3:"
    refute mr_body =~ "AC-4:"
    assert mr_body =~ "[PPL-123](https://jira.example/PPL-123)"
    refute mr_body =~ "## Ticket Delivery Contract"
    refute mr_body =~ contract.markdown
    refute mr_body =~ "pipeline"
    refute mr_body =~ "bazel"
    refute mr_body =~ "Automated checks and independent verification"
    refute mr_body =~ "- [x]"
    refute mr_body =~ "- [ ]"
    assert String.length(mr_body) < String.length(contract.markdown)
    assert length(Regex.scan(~r/^## (?:Summary|Test plan)$/m, mr_body)) == 2

    assert {:ok, delivered} = RunLedger.get(store, run["run_id"])
    assert delivered["state"] == "READY_FOR_REVIEW"
    assert delivered["candidate_sha"] == candidate
    assert delivered["mr_url"] == mr_url
  end

  test "Grail CI preflight creates one draft MR before verification and waits for exact-SHA CI", %{
    context: context,
    store: store
  } do
    candidate = String.duplicate("a", 40)
    route = put_in(context.factory.repositories["grail"]["ci_preflight"], "draft_mr")

    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"
      )

    snapshot = authorized_snapshot(contract, ["ai-running", "repo-grail"])

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "preflight-run",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "CI_PUSHING",
               dispatcher_id: "dispatcher-1",
               repo_key: "grail",
               repo_path: route.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: route.factory.repositories["grail"]["path"],
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               snapshot_json: Jason.encode!(snapshot),
               contract_markdown: contract.markdown,
               contract_sha256: contract.sha256,
               spec_revision: 1,
               verifier_round: 1
             })

    mr_url = "https://gitlab.example/grailbio/grail/-/merge_requests/7"

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{
        "status" => "PASS",
        "mr_url" => mr_url,
        "iid" => 7,
        "source_branch" => "cgable/PPL-123-factory-work",
        "target_branch" => "master",
        "sha" => candidate,
        "draft" => true,
        "reviewers_count" => 0,
        "assignee_id" => 11_599_766,
        "state" => "opened"
      }
    ])

    assert {:ok, _result} = tick(route)
    assert_received {:push_exact, "cgable/PPL-123-factory-work", ^candidate}
    assert {:ok, %{"state" => "CI_WAITING", "mr_url" => ^mr_url}} = RunLedger.get(store, run["run_id"])
    refute_received {:stage_launch, _, _, _, _}
    refute_received {:jira_write_options, _}

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{
        "status" => "PASS",
        "mr_url" => mr_url,
        "iid" => 7,
        "source_branch" => "cgable/PPL-123-factory-work",
        "target_branch" => "master",
        "draft" => true,
        "reviewers_count" => 0,
        "assignee_id" => 11_599_766,
        "mr_state" => "opened",
        "sha" => candidate,
        "pipeline_id" => 99,
        "pipeline_url" => "https://gitlab.example/grailbio/grail/-/pipelines/99",
        "pipeline_sha" => "caaa52a6a6c87771f00fae20505675f7b628436b",
        "pipeline_ref" => "refs/merge-requests/7/merge",
        "pipeline_source" => "merge_request_event",
        "pipeline_status" => "success",
        "required_jobs" => [%{"id" => 88, "name" => "bazel", "status" => "success", "web_url" => "https://gitlab.example/jobs/88"}],
        "findings" => []
      }
    ])

    assert {:ok, _result} = tick(route)
    assert {:ok, %{"state" => "VERIFYING", "ci_pipeline_id" => 99}} = RunLedger.get(store, run["run_id"])

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [verifier]}} = tick(route)
    assert verifier.task_key == "preflight-run:change-verifier:2"

    complete_task(store, verifier.task_key, %{
      "status" => "PASS",
      "candidate_sha" => candidate,
      "findings" => [],
      "checks" => ["independent review passed", "CI pipeline 99 bazel job 88 passed"]
    })

    Process.exit(verifier.pid, :kill)

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, _result} = tick(route)
    assert {:ok, %{"state" => "MR_CREATING"}} = RunLedger.get(store, run["run_id"])
    refute_received {:push_exact, _, _}

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{
        "status" => "PASS",
        "mr_url" => mr_url,
        "iid" => 7,
        "source_branch" => "cgable/PPL-123-factory-work",
        "target_branch" => "master",
        "sha" => candidate,
        "draft" => true,
        "reviewers_count" => 0,
        "assignee_id" => 11_599_766,
        "state" => "opened"
      },
      jira_write_response(["ai-review", "repo-grail"], mr_url)
    ])

    assert {:ok, _result} = tick(route)

    assert {:ok, %{"state" => "READY_FOR_REVIEW", "candidate_sha" => ^candidate}} =
             RunLedger.get(store, run["run_id"])
  end

  test "runs Slack-coordinated exact-SHA manual validation before human review", %{
    context: context,
    store: store
  } do
    candidate = String.duplicate("a", 40)
    mr_url = "https://gitlab.example/grailbio/grail/-/merge_requests/8"

    contract =
      Contract.bind(
        "PPL-123",
        1,
        """
        # Contract

        ## Acceptance Criteria
        - AC-1: works

        ## Manual Validation
        - Required: yes
        - Environment: cpp-test
        - Service: doc-extract
        - Cases: MV-1
        - MV-1: Submit synthetic vote requests and verify the threshold override affects only that request.
        - Synthetic data: required
        - Evidence: command output
        - Teardown: remove synthetic resources; no DDL
        """
      )

    snapshot = authorized_snapshot(contract, ["ai-testing", "repo-grail"])
    writer_path = Path.join(context.workspace_root, "parent-writer")
    File.mkdir_p!(writer_path)

    assert {:ok, %{run: parent}} =
             RunLedger.register(store, %{
               run_id: "parent-delivery",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "AWAITING_VALIDATION",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: true,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: writer_path,
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               mr_url: mr_url,
               mr_iid: 8,
               snapshot_json: Jason.encode!(snapshot)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [validator]}} = tick(context)
    assert validator.task_key =~ "manual-validator"
    assert_receive {:stage_launch, validation_run_id, _workspace, _prompt, stage_opts}
    assert is_binary(validation_run_id)
    assert stage_opts[:required_apps] == ["polaris-app"]
    assert stage_opts[:required_mcp_servers] == []
    assert stage_opts[:mcp_startup_timeout_ms] == 45_000

    complete_task(store, validator.task_key, %{
      "status" => "PASS",
      "candidate_sha" => candidate,
      "evidence_markdown" => "MV-1 passed with attached command output.",
      "findings" => [],
      "human_action" => nil,
      "environment" => "cpp-test",
      "slack_claim_ts" => "1710000000.000001",
      "slack_release_confirmed" => true,
      "teardown_confirmed" => true,
      "synthetic_data_only" => true
    })

    Process.exit(validator.pid, :kill)

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      %{
        "status" => "PASS",
        "mr_url" => mr_url,
        "iid" => 8,
        "source_branch" => "cgable/PPL-123-factory-work",
        "target_branch" => "master",
        "sha" => candidate,
        "draft" => true,
        "reviewers_count" => 0,
        "assignee_id" => 11_599_766,
        "state" => "opened"
      },
      jira_write_response(["ai-review", "repo-grail"], candidate)
    ])

    assert {:ok, result} = tick(context)
    assert Enum.any?(result.events, &(&1.event == "VALIDATION_PASSED"))

    prompts =
      self()
      |> Process.info(:messages)
      |> elem(1)
      |> Enum.flat_map(fn
        {:controller_prompt, prompt} -> [prompt]
        _message -> []
      end)

    [validation_prompt] = Enum.filter(prompts, &String.contains?(&1, "MR description:\n"))
    [_, validation_body] = String.split(validation_prompt, "MR description:\n", parts: 2)
    assert validation_body =~ "### Manual testing"
    assert validation_body =~ "- Environment: cpp-test; Service: doc-extract; Cases: MV-1; MV-1: Submit synthetic vote requests and verify the threshold override affects only that request."
    assert validation_body =~ "MV-1 passed with attached command output."
    refute validation_body =~ "## Ticket Delivery Contract"

    [validation] = Enum.filter(RunLedger.list(store), &(&1["kind"] == "VALIDATION"))
    assert validation["state"] == "READY_FOR_REVIEW"
    assert validation["validation_attempt"] == 1
    assert {:ok, %{"state" => "READY_FOR_REVIEW"}} = RunLedger.get(store, parent["run_id"])
  end

  test "rejects validation evidence from another allowed environment", %{context: context, store: store} do
    candidate = String.duplicate("a", 40)
    mr_url = "https://gitlab.example/grailbio/grail/-/merge_requests/8"
    manual_validation = Map.put(context.factory.manual_validation, "allowed_environments", ["cpp-test", "cpp-dev"])
    context = %{context | factory: %{context.factory | manual_validation: manual_validation}}

    contract =
      Contract.bind(
        "PPL-123",
        1,
        """
        # Contract

        ## Acceptance Criteria
        - AC-1: works

        ## Manual Validation
        - Required: yes
        - Environment: cpp-test
        - Service: doc-extract
        - Cases: MV-1
        - Synthetic data: required
        - Evidence: command output
        - Teardown: remove synthetic resources; no DDL
        """
      )

    snapshot = authorized_snapshot(contract, ["ai-testing", "repo-grail"])

    assert {:ok, %{run: parent}} =
             RunLedger.register(store, %{
               run_id: "parent-delivery",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "AWAITING_VALIDATION",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: true,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               mr_url: mr_url,
               mr_iid: 8,
               snapshot_json: Jason.encode!(snapshot)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [validator]}} = tick(context)

    complete_task(store, validator.task_key, %{
      "status" => "PASS",
      "candidate_sha" => candidate,
      "evidence_markdown" => "MV-1 passed in cpp-dev.",
      "findings" => [],
      "human_action" => nil,
      "environment" => "cpp-dev",
      "slack_claim_ts" => "1710000000.000001",
      "slack_release_confirmed" => true,
      "teardown_confirmed" => true,
      "synthetic_data_only" => true
    })

    Process.exit(validator.pid, :kill)

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      jira_write_response(["ai-blocked", "repo-grail"], "AI factory blocked:")
    ])

    assert {:ok, result} = tick(context)
    refute Enum.any?(result.events, &(&1.event == "VALIDATION_PASSED"))
    assert_received {:jira_write_options, write_options}

    assert [%{labels_equals: labels}] =
             Enum.filter(write_options[:allowed_mcp_tool_approvals], &(&1.tool == "jira_update_issue"))

    refute "ai-review" in labels
    [validation] = Enum.filter(RunLedger.list(store), &(&1["kind"] == "VALIDATION"))
    assert validation["state"] == "FAILED"
    assert validation["last_error"] =~ "manual_validation_environment_mismatch"
    assert {:ok, %{"state" => "AWAITING_VALIDATION"}} = RunLedger.get(store, parent["run_id"])
  end

  test "rejects a validation PASS after manual validation is disabled", %{context: context, store: store} do
    candidate = String.duplicate("a", 40)
    contract = Contract.bind("PPL-123", 1, "## Manual Validation\n- Required: yes\n- Environment: cpp-test")
    snapshot = authorized_snapshot(contract, ["ai-testing", "repo-grail"])

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "validation-run",
               issue_key: "PPL-123",
               kind: "VALIDATION",
               state: "TESTING",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: true,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               mr_url: "https://gitlab.example/grailbio/grail/-/merge_requests/8",
               mr_iid: 8,
               snapshot_json: Jason.encode!(snapshot)
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [validator]}} = tick(context)

    complete_task(store, validator.task_key, %{
      "status" => "PASS",
      "candidate_sha" => candidate,
      "evidence_markdown" => "MV-1 passed in cpp-test.",
      "findings" => [],
      "human_action" => nil,
      "environment" => "cpp-test",
      "slack_claim_ts" => "1710000000.000001",
      "slack_release_confirmed" => true,
      "teardown_confirmed" => true,
      "synthetic_data_only" => true
    })

    Process.exit(validator.pid, :kill)
    manual_validation = Map.put(context.factory.manual_validation, "enabled", false)
    disabled_context = %{context | factory: %{context.factory | manual_validation: manual_validation}}

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      jira_write_response(["ai-blocked", "repo-grail"], "AI factory blocked:")
    ])

    assert {:ok, result} = tick(disabled_context)
    refute Enum.any?(result.events, &(&1.event == "VALIDATION_PASSED"))
    assert {:ok, failed} = RunLedger.get(store, run["run_id"])
    assert failed["state"] == "FAILED"
    assert failed["last_error"] =~ "manual_validation_disabled"
    refute Enum.any?(result.events, &(&1.event == "VALIDATION_PASSED"))
    assert_received {:jira_write_options, write_options}

    assert [%{labels_equals: labels}] =
             Enum.filter(write_options[:allowed_mcp_tool_approvals], &(&1.tool == "jira_update_issue"))

    refute "ai-review" in labels
  end

  test "does not launch a validator after manual validation is disabled", %{context: context, store: store} do
    candidate = String.duplicate("a", 40)
    contract = Contract.bind("PPL-123", 1, "## Manual Validation\n- Required: yes\n- Environment: cpp-test")
    snapshot = authorized_snapshot(contract, ["ai-testing", "repo-grail"])

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "validation-run",
               issue_key: "PPL-123",
               kind: "VALIDATION",
               state: "TESTING",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: true,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               mr_url: "https://gitlab.example/grailbio/grail/-/merge_requests/8",
               mr_iid: 8,
               snapshot_json: Jason.encode!(snapshot)
             })

    manual_validation = Map.put(context.factory.manual_validation, "enabled", false)
    disabled_context = %{context | factory: %{context.factory | manual_validation: manual_validation}}

    Process.put(:factory_controller_responses, [
      intake_response(snapshot),
      jira_write_response(["ai-blocked", "repo-grail"], "AI factory blocked:")
    ])

    assert {:ok, result} = tick(disabled_context)
    assert result.launches == []
    refute_received {:stage_launch, "validation-run", _workspace, _prompt, _options}
    assert {:ok, failed} = RunLedger.get(store, run["run_id"])
    assert failed["state"] == "FAILED"
    assert failed["last_error"] =~ "manual_validation_disabled"
  end

  test "rehydrates the retained branch and exact candidate before a repair writer resumes", %{
    context: context,
    store: store
  } do
    candidate = String.duplicate("a", 40)

    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n## Manual Validation\n- Required: no\n- Reason: deterministic tests"
      )

    snapshot = authorized_snapshot(contract, ["ai-running", "repo-grail"])
    missing_worktree = Path.join(context.workspace_root, "removed-writer")

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "repair-delivery",
               issue_key: "PPL-123",
               kind: "DELIVERY",
               state: "REPAIRING",
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: false,
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               worktree: missing_worktree,
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: candidate,
               plan_markdown: "Repair AC-1",
               snapshot_json: Jason.encode!(snapshot),
               workspace_state: "HIBERNATED"
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [writer]} = result} = tick(context)

    assert_receive {:ensure_writer, route, "PPL-123", "repair-delivery"}
    assert route["branch"] == "cgable/PPL-123-factory-work"
    assert route["expected_sha"] == candidate
    assert Enum.any?(result.events, &(&1.event == "WORKTREE_REHYDRATED"))

    assert {:ok, materialized} = RunLedger.get(store, run["run_id"])
    assert materialized["workspace_state"] == "MATERIALIZED"
    assert File.dir?(materialized["worktree"])
    Process.exit(writer.pid, :kill)
  end

  for state <- ["SPEC_REVIEW", "PLANNING", "VERIFYING", "TESTING"] do
    test "native #{state} launches from the primary only as pinned CREATE metadata", %{
      context: context,
      store: store
    } do
      {context, snapshot, run} = native_stage_fixture(context, store, unquote(state))
      Process.put(:factory_controller_response, intake_response(snapshot))

      assert {:ok, %{launches: [stage]}} = tick(context)
      assert_receive {:stage_launch, run_id, workspace, _prompt, opts}
      assert run_id == run["run_id"]
      assert workspace == context.factory.repositories["grail"]["path"]
      assert opts[:task_transport] == "desktop_broker"
      assert opts[:expected_sha] == native_stage_sha(unquote(state))
      refute_received {:create_detached, _, _}
      refute_received {:removed_detached, _}
      Process.exit(stage.pid, :kill)
    end
  end

  test "native planner reuses its pinned bound checkout after the base moves and preserves it", %{
    context: context,
    store: store
  } do
    {context, snapshot, run} = native_stage_fixture(context, store, "PLANNING")
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [planner]}} = tick(context)
    Process.exit(planner.pid, :kill)

    native_path = Path.join(context.workspace_root, "codex-native-planner")
    File.mkdir_p!(native_path)

    assert {:ok, _task} =
             TaskLedger.update(store, planner.task_key, %{
               workspace: native_path,
               workspace_sha: native_stage_sha("PLANNING"),
               thread_id: "native-planner-thread"
             })

    Process.put(:factory_base_sha, String.duplicate("c", 40))
    complete_task(store, planner.task_key, %{"status" => "PLANNED", "plan_markdown" => "Implement AC-1", "blockers" => []})
    Process.put(:factory_controller_response, intake_response(snapshot))

    assert {:ok, _result} = tick(context)
    assert_received {:validate_native, ^native_path, [expected_sha: expected_sha]}
    assert expected_sha == native_stage_sha("PLANNING")
    assert {:ok, %{"state" => "ADMITTING_WRITER"}} = RunLedger.get(store, run["run_id"])
    assert File.dir?(native_path)
    refute_received {:removed_detached, ^native_path}
    refute_received {:create_detached, _, _}
  end

  test "a missing bound native planner checkout blocks without creating a replacement", %{
    context: context,
    store: store
  } do
    {context, snapshot, run} = native_stage_fixture(context, store, "PLANNING")
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [planner]}} = tick(context)
    Process.exit(planner.pid, :kill)

    missing_path = Path.join(context.workspace_root, "missing-native-planner")

    assert {:ok, _task} =
             TaskLedger.update(store, planner.task_key, %{
               workspace: missing_path,
               workspace_sha: native_stage_sha("PLANNING"),
               thread_id: "native-planner-thread"
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED", "failure_code" => failure}} = RunLedger.get(store, run["run_id"])
    assert failure =~ "native_worktree_missing"
    refute_received {:create_detached, _, _}
    refute_received {:removed_detached, _}
  end

  test "a native stage with a thread but no workspace binding blocks before relaunch", %{
    context: context,
    store: store
  } do
    {context, snapshot, run} = native_stage_fixture(context, store, "PLANNING")
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [planner]}} = tick(context)
    Process.exit(planner.pid, :kill)
    assert {:ok, _task} = TaskLedger.update(store, planner.task_key, %{thread_id: "native-planner-thread"})

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED", "failure_code" => failure}} = RunLedger.get(store, run["run_id"])
    assert failure =~ "native_stage_workspace_unbound"
    refute_received {:create_detached, _, _}
  end

  test "an active native run blocks if transport switches to app-server", %{context: context, store: store} do
    {_native_context, snapshot, run} = native_stage_fixture(context, store, "PLANNING")
    Process.put(:factory_controller_response, intake_response(snapshot))

    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED", "failure_code" => failure}} = RunLedger.get(store, run["run_id"])
    assert failure =~ "factory_task_transport_changed"
    refute_received {:create_detached, _, _}
  end

  test "native writer admission and launch do not create a factory writer", %{context: context, store: store} do
    {context, snapshot, run} = native_stage_fixture(context, store, "ADMITTING_WRITER")

    Process.put(:factory_controller_response, intake_response(snapshot))

    assert {:ok, _result} = tick(context)

    assert {:ok, %{"state" => "WRITING", "worktree" => nil, "factory_owned" => 0}} =
             RunLedger.get(store, run["run_id"])

    refute_received {:ensure_writer, _, _, _}

    running_snapshot = %{snapshot | "labels" => ["ai-running", "repo-grail"]}
    Process.put(:factory_controller_response, intake_response(running_snapshot))
    assert {:ok, %{launches: [writer]}} = tick(context)
    assert_receive {:stage_launch, _, workspace, _, opts}
    assert workspace == context.factory.repositories["grail"]["path"]
    assert opts[:expected_sha] == native_stage_sha("PLANNING")
    refute_received {:ensure_writer, _, _, _}
    Process.exit(writer.pid, :kill)
  end

  test "a missing bound native writer checkout blocks without rehydrating it", %{context: context, store: store} do
    {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
    missing_path = Path.join(context.workspace_root, "missing-native-writer")
    assert {:ok, _updated} = RunLedger.update(store, run["run_id"], %{worktree: missing_path})

    assert {:ok, _task} = register_native_writer_task(store, run, missing_path)

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED", "failure_code" => failure}} = RunLedger.get(store, run["run_id"])
    assert failure =~ "native_worktree_missing"
    refute_received {:ensure_writer, _, _, _}
    refute_received {:removed_detached, _}
  end

  test "a native writer awaiting Desktop readback keeps its in-progress source edits", %{
    context: context,
    store: store
  } do
    {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
    native_path = Path.join(context.workspace_root, "editing-native-writer")
    File.mkdir_p!(native_path)
    assert {:ok, _run} = RunLedger.update(store, run["run_id"], %{worktree: native_path})

    assert {:ok, _task} =
             register_native_writer_task(store, run, native_path, status: "WAITING_FOR_BROKER")

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    assert_received {:validate_native, ^native_path, opts}
    assert opts[:clean] == false
    assert opts[:expected_branch] == run["branch"]
    assert {:ok, %{"state" => "WRITING"}} = RunLedger.get(store, run["run_id"])
  end

  test "a restarted native writer with a prior turn may keep partial edits while starting", %{
    context: context,
    store: store
  } do
    {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
    native_path = Path.join(context.workspace_root, "restarting-native-writer")
    File.mkdir_p!(native_path)
    assert {:ok, _run} = RunLedger.update(store, run["run_id"], %{worktree: native_path})

    assert {:ok, _task} =
             register_native_writer_task(store, run, native_path,
               status: "STARTING",
               turn_id: "interrupted-turn"
             )

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [writer]}} = tick(context)
    assert_received {:validate_native, ^native_path, opts}
    assert opts[:clean] == false
    assert opts[:expected_branch] == run["branch"]
    assert {:ok, %{"state" => "WRITING"}} = RunLedger.get(store, run["run_id"])
    Process.exit(writer.pid, :kill)
  end

  test "native writer accepts only the pinned detached checkout before bootstrap finishes", %{
    context: context,
    store: store
  } do
    {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
    native_path = Path.join(context.workspace_root, "detached-native-writer")
    File.mkdir_p!(native_path)
    Process.put({:native_detached, native_path}, true)
    Process.put({:native_head_sha, native_path}, native_stage_sha("PLANNING"))
    assert {:ok, _run} = RunLedger.update(store, run["run_id"], %{worktree: native_path})
    assert {:ok, _task} = register_native_writer_task(store, run, native_path, status: "STARTING")

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: [writer]}} = tick(context)
    assert_receive {:validate_native, ^native_path, opts}
    assert opts[:clean] == true
    assert opts[:expected_branch] == run["branch"]
    assert_receive {:validate_native, ^native_path, [expected_sha: expected_sha]}
    assert expected_sha == native_stage_sha("PLANNING")
    assert_receive {:stage_launch, _, ^native_path, _, _}
    Process.exit(writer.pid, :kill)

    assert {:ok, _task} = TaskLedger.update(store, writer.task_key, %{turn_id: "completed-turn"})
    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED", "failure_code" => failure}} = RunLedger.get(store, run["run_id"])
    assert failure =~ "native_worktree_branch_mismatch"
    refute_received {:ensure_writer, _, _, _}
  end

  test "native writer rejects a new commit before its next turn", %{context: context, store: store} do
    {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
    native_path = Path.join(context.workspace_root, "advanced-native-writer")
    File.mkdir_p!(native_path)
    candidate = String.duplicate("a", 40)
    drifted = String.duplicate("d", 40)
    Process.put({:native_head_sha, native_path}, drifted)
    assert {:ok, _run} = RunLedger.update(store, run["run_id"], %{worktree: native_path, candidate_sha: candidate})

    assert {:ok, _task} =
             register_native_writer_task(store, run, native_path, status: "CONSUMED", turn_id: "previous-turn")

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)
    assert {:ok, %{"state" => "FAILED", "failure_code" => failure}} = RunLedger.get(store, run["run_id"])
    assert failure =~ "native_worktree_sha_mismatch"
    assert_received {:validate_native, ^native_path, opts}
    assert opts[:expected_sha] == candidate
    refute_received {:ensure_writer, _, _, _}
  end

  for marker <- ["BLOCKED_NATIVE_WRITER_INVESTIGATION_REARMED", "CONTRACT_REVISION_REARMED"] do
    test "native writer resumes #{marker} with dirty edits at the pinned SHA", %{
      context: context,
      store: store
    } do
      {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
      native_path = Path.join(context.workspace_root, "rearmed-native-writer")
      File.mkdir_p!(native_path)
      candidate = String.duplicate("a", 40)
      Process.put({:native_head_sha, native_path}, candidate)

      assert {:ok, _run} =
               RunLedger.update(store, run["run_id"], %{worktree: native_path, candidate_sha: candidate})

      assert {:ok, task} =
               register_native_writer_task(store, run, native_path, status: "CONSUMED", turn_id: "blocked-turn")

      assert {:ok, _task} =
               TaskLedger.update(store, task["task_key"], %{
                 workspace_sha: candidate,
                 failure_code: unquote(marker)
               })

      Process.put(:factory_controller_response, intake_response(snapshot))
      assert {:ok, %{launches: [writer]}} = tick(context)
      assert_received {:validate_native, ^native_path, opts}
      assert opts[:clean] == false
      assert opts[:expected_sha] == candidate
      assert opts[:expected_branch] == run["branch"]
      Process.exit(writer.pid, :kill)
    end
  end

  test "an authorized In Dev delivery remains eligible while its revised contract is ai-ready", %{
    context: context,
    store: store
  } do
    {context, original, run} = native_stage_fixture(context, store, "WRITING")
    current = original |> Map.put("status", "In Dev") |> Map.put("labels", ["ai-ready", "repo-grail"])
    native_path = Path.join(context.workspace_root, "revised-native-writer")
    File.mkdir_p!(native_path)
    candidate = String.duplicate("a", 40)
    Process.put({:native_head_sha, native_path}, candidate)
    Process.put(:factory_jira_issue, current)

    assert {:ok, _run} =
             RunLedger.update(store, run["run_id"], %{
               worktree: native_path,
               candidate_sha: candidate,
               snapshot_json: Jason.encode!(current)
             })

    assert {:ok, _task} =
             register_native_writer_task(store, run, native_path, status: "CONSUMED", turn_id: "previous-turn")

    Process.put(:factory_controller_response, intake_response(current))
    assert {:ok, %{launches: [writer]}} = tick(context)
    assert {:ok, %{"state" => "WRITING", "implementation_iteration" => 0}} = RunLedger.get(store, run["run_id"])
    Process.exit(writer.pid, :kill)
  end

  test "native writer consumes a completed turn that advanced the candidate SHA", %{context: context, store: store} do
    {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
    native_path = Path.join(context.workspace_root, "completed-native-writer")
    File.mkdir_p!(native_path)
    previous_candidate = String.duplicate("a", 40)
    committed_candidate = String.duplicate("d", 40)
    Process.put({:native_head_sha, native_path}, previous_candidate)
    Process.put({:factory_candidate, native_path}, committed_candidate)

    assert {:ok, _run} =
             RunLedger.update(store, run["run_id"], %{worktree: native_path, candidate_sha: previous_candidate})

    assert {:ok, task} =
             register_native_writer_task(store, run, native_path, status: "COMPLETE", turn_id: "completed-turn")

    assert {:ok, _task} =
             TaskLedger.update(store, task["task_key"], %{
               output_json:
                 Jason.encode!(%{
                   "status" => "CONTINUE",
                   "changed_paths" => ["feature.txt"],
                   "commit_message" => "feat(PPL-123): add feature"
                 })
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)

    assert {:ok, %{"state" => "WRITING", "candidate_sha" => ^committed_candidate}} =
             RunLedger.get(store, run["run_id"])

    assert_received {:validate_native, ^native_path, opts}
    assert opts[:expected_branch] == run["branch"]
    assert opts[:expected_sha] == nil
    assert_received {:commit_native_slice, ^native_path, _, ^previous_candidate, ["feature.txt"], _}
  end

  for {writer_status, expected_state} <- [{"CONTINUE", "REPAIRING"}, {"COMPLETE", "VERIFYING"}] do
    test "native repair writer #{writer_status} records its committed slice", %{context: context, store: store} do
      {context, snapshot, run} = native_stage_fixture(context, store, "REPAIRING")
      native_path = Path.join(context.workspace_root, "completed-repair-native-writer")
      File.mkdir_p!(native_path)
      previous_candidate = String.duplicate("a", 40)
      committed_candidate = String.duplicate("d", 40)
      Process.put({:native_head_sha, native_path}, previous_candidate)
      Process.put({:factory_candidate, native_path}, committed_candidate)

      assert {:ok, _run} =
               RunLedger.update(store, run["run_id"], %{worktree: native_path, candidate_sha: previous_candidate})

      assert {:ok, task} =
               register_native_writer_task(store, run, native_path, status: "COMPLETE", turn_id: "repair-turn")

      assert {:ok, _task} =
               TaskLedger.update(store, task["task_key"], %{
                 output_json:
                   Jason.encode!(%{
                     "status" => unquote(writer_status),
                     "changed_paths" => ["repair.txt"],
                     "commit_message" => "test(PPL-123): cover repaired behavior"
                   })
               })

      Process.put(:factory_controller_response, intake_response(snapshot))
      assert {:ok, %{launches: []}} = tick(context)

      assert {:ok, %{"state" => unquote(expected_state), "candidate_sha" => ^committed_candidate}} =
               RunLedger.get(store, run["run_id"])

      assert_received {:commit_native_slice, ^native_path, _, ^previous_candidate, ["repair.txt"], _}
    end
  end

  test "native writer completes without a new commit when its prior slice already satisfies the contract", %{
    context: context,
    store: store
  } do
    {context, snapshot, run} = native_stage_fixture(context, store, "WRITING")
    native_path = Path.join(context.workspace_root, "completed-clean-native-writer")
    File.mkdir_p!(native_path)
    candidate = String.duplicate("a", 40)
    Process.put({:native_head_sha, native_path}, candidate)
    Process.put({:factory_candidate, native_path}, candidate)

    assert {:ok, _run} =
             RunLedger.update(store, run["run_id"], %{worktree: native_path, candidate_sha: candidate})

    assert {:ok, task} =
             register_native_writer_task(store, run, native_path, status: "COMPLETE", turn_id: "completed-turn")

    assert {:ok, _task} =
             TaskLedger.update(store, task["task_key"], %{
               output_json:
                 Jason.encode!(%{
                   "status" => "COMPLETE",
                   "changed_paths" => [],
                   "commit_message" => nil
                 })
             })

    Process.put(:factory_controller_response, intake_response(snapshot))
    assert {:ok, %{launches: []}} = tick(context)

    assert {:ok, %{"state" => "VERIFYING", "candidate_sha" => ^candidate}} =
             RunLedger.get(store, run["run_id"])

    refute_received {:commit_native_slice, _, _, _, _, _}
  end

  defp register_native_writer_task(store, run, path, opts \\ []) do
    attrs = %{
      task_key: "#{run["run_id"]}:feature-writer",
      run_id: run["run_id"],
      stage: "WRITING",
      role: "feature-writer",
      status: Keyword.get(opts, :status, "RUNNING"),
      model_provider: "codex",
      model_class: "test",
      model: "gpt-test",
      reasoning_effort: "medium",
      routing_reason: "test",
      prompt_sha256: String.duplicate("a", 64),
      workspace: path,
      workspace_sha: native_stage_sha("PLANNING"),
      thread_id: "native-writer-thread"
    }

    with {:ok, task} <- TaskLedger.register(store, attrs) do
      case Keyword.get(opts, :turn_id) do
        nil -> {:ok, task}
        turn_id -> TaskLedger.update(store, task["task_key"], %{turn_id: turn_id})
      end
    end
  end

  defp native_stage_fixture(context, store, state) do
    context = %{context | factory: Map.put(context.factory, :task_transport, "desktop_broker")}

    manual_validation =
      if state == "TESTING",
        do: "## Manual Validation\n- Required: yes\n- Environment: cpp-test",
        else: "## Manual Validation\n- Required: no\n- Reason: deterministic tests"

    contract =
      Contract.bind(
        "PPL-123",
        1,
        "# Contract\n\n## Acceptance Criteria\n- AC-1: works\n\n#{manual_validation}"
      )

    kind = native_stage_kind(state)
    labels = native_stage_labels(state)

    snapshot = if kind == "SPECIFICATION", do: snapshot(labels), else: authorized_snapshot(contract, labels)
    Process.put(:factory_jira_issue, snapshot)

    assert {:ok, %{run: run}} =
             RunLedger.register(store, %{
               run_id: "native-#{String.downcase(state)}",
               issue_key: "PPL-123",
               kind: kind,
               state: state,
               dispatcher_id: "dispatcher-1",
               spec_revision: 1,
               verifier_round: 1,
               contract_sha256: contract.sha256,
               contract_markdown: contract.markdown,
               manual_validation_required: state == "TESTING",
               plan_markdown: "Implement AC-1",
               repo_key: "grail",
               repo_path: context.factory.repositories["grail"]["path"],
               base_branch: "master",
               branch: "cgable/PPL-123-factory-work",
               candidate_sha: if(state in ["VERIFYING", "TESTING"], do: native_stage_sha(state)),
               snapshot_json: Jason.encode!(snapshot),
               factory_owned: false
             })

    {context, snapshot, run}
  end

  defp native_stage_sha(state) when state in ["VERIFYING", "TESTING"], do: String.duplicate("a", 40)
  defp native_stage_sha(_state), do: String.duplicate("b", 40)

  defp native_stage_kind("SPEC_REVIEW"), do: "SPECIFICATION"
  defp native_stage_kind("TESTING"), do: "VALIDATION"
  defp native_stage_kind(_state), do: "DELIVERY"

  defp native_stage_labels("SPEC_REVIEW"), do: ["spec-needed", "repo-grail"]
  defp native_stage_labels("PLANNING"), do: ["ai-ready", "repo-grail"]
  defp native_stage_labels("TESTING"), do: ["ai-testing", "repo-grail"]
  defp native_stage_labels(_state), do: ["ai-running", "repo-grail"]

  defp intake_response(snapshot) do
    %{
      "status" => "PASS",
      "issue_key" => "QUEUE",
      "snapshot_json" => Jason.encode!([snapshot])
    }
  end

  defp authorized_snapshot(contract, labels) do
    snapshot(labels)
    |> Map.put("comments", [
      %{"id" => "1", "text" => Contract.draft_comment(contract)},
      %{"id" => "2", "text" => Contract.confirmation_marker(contract)},
      %{"id" => "3", "text" => Contract.authorization_marker(contract, "2")}
    ])
  end

  defp jira_write_response(labels, readback) do
    %{
      "status" => "PASS",
      "issue_key" => "PPL-123",
      "operation" => "test",
      "comment_id" => nil,
      "labels" => labels,
      "readback_text" => readback
    }
  end

  defp complete_task(store, task_key, output) do
    assert {:ok, _task} =
             TaskLedger.update(store, task_key, %{
               status: "COMPLETE",
               output_json: Jason.encode!(output)
             })
  end

  defp tick(context) do
    Scheduler.tick(context,
      controller_task: FakeControllerTask,
      jira_connector: FakeJiraConnector,
      task_launcher: FakeTaskLauncher,
      cleanup: FakeCleanup,
      worktree: FakeWorktree
    )
  end

  defp snapshot(labels) do
    %{
      "id" => "100",
      "key" => "PPL-123",
      "summary" => "Factory work",
      "description" => "Do the work",
      "status" => "READY",
      "labels" => labels,
      "assignee" => "cgable",
      "project_key" => "PPL",
      "parent_key" => nil,
      "components" => ["doc-extract"],
      "url" => "https://jira.example/PPL-123",
      "updated" => "2026-09-21T00:00:00Z",
      "comments" => []
    }
  end
end
