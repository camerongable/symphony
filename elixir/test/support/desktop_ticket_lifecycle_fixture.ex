defmodule SymphonyElixir.DesktopTicketLifecycleFixture do
  @moduledoc false
  alias SymphonyElixir.Factory.{TicketWorkerRunner, WorkerFileTools}

  defmodule NativeReader do
    @moduledoc false
    def read_native_thread(thread_id, opts), do: {:ok, Process.get(:lifecycle_native, %{"id" => thread_id, "cwd" => opts[:workspace], "projectId" => nil, "turns" => []})}
  end

  defmodule CriticServer do
    @moduledoc false
    alias SymphonyElixir.Factory.TicketWorkerRunner

    def start_session(workspace, opts) do
      Process.put(:lifecycle_critic_invocations, Process.get(:lifecycle_critic_invocations, 0) + 1)
      thread_id = "critic-fixture"
      if is_function(opts[:on_thread_created], 1), do: opts[:on_thread_created].(thread_id)

      {:ok,
       %{
         thread_id: thread_id,
         workspace: workspace,
         worker_policy: TicketWorkerRunner.policy("REVIEW", workspace),
         worker_invocation: String.duplicate("a", 64),
         metadata: %{codex_app_server_pid: "12345"}
       }}
    end

    def run_turn(session, _prompt, _issue, opts) do
      turn_id = "critic-turn"
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn_id})

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "threadId" => session.thread_id,
            "turnId" => turn_id,
            "item" => %{
              "id" => "critic-item",
              "type" => "agentMessage",
              "text" => Jason.encode!(Process.get(:lifecycle_critic_output, %{"status" => "PASS", "findings" => [], "required_questions" => []}))
            }
          }
        }
      })

      {:ok, %{turn_id: turn_id}}
    end

    def stop_session(session),
      do:
        {:ok,
         %{
           "transport" => "owned_app_server",
           "thread_id" => session.thread_id,
           "pid" => "12345",
           "invocation_nonce" => session.worker_invocation,
           "cwd" => session.workspace,
           "exit_status" => 0
         }}
  end

  defmodule JiraReader do
    @moduledoc false
    def search(_query, _opts) do
      Process.put(:lifecycle_jira_search_calls, Process.get(:lifecycle_jira_search_calls, 0) + 1)
      {:ok, Process.get(:lifecycle_jira_search, [])}
    end

    def issue(_key, _opts) do
      current = Process.get(:lifecycle_jira)

      drafts = Enum.count(current["comments"] || [], &String.contains?(&1["text"] || "", "AI FACTORY CONTRACT BEGIN"))
      automatic_authorization? = Enum.any?(current["comments"] || [], &String.contains?(&1["text"] || "", "mode=automatic critic-task-key="))

      stale_draft? = Process.get(:lifecycle_stale_draft_readback, false) and drafts >= 2
      stale_authorization? = Process.get(:lifecycle_stale_auth_readback, false) and automatic_authorization?

      if stale_draft? or stale_authorization? do
        Process.put(:lifecycle_stale_draft_readback, false)
        Process.put(:lifecycle_stale_auth_readback, false)
        {:ok, Process.get(:lifecycle_jira_pre_write)}
      else
        {:ok, current}
      end
    end
  end

  defmodule JiraConnector do
    @moduledoc false
    import ExUnit.Assertions

    def validate_call(_tool, _args, opts) do
      assert opts[:mcp_session] == %{thread_id: "jira-fixture"}
      :ok
    end

    def call_list("jira_get_transitions", _args, opts) do
      validate_call(nil, nil, opts)
      {:ok, [%{"id" => "11", "to_status" => "In Dev"}]}
    end

    def call(tool, args, opts) do
      validate_call(tool, args, opts)
      snapshot = Process.get(:lifecycle_jira)
      Process.put(:lifecycle_jira_calls, Process.get(:lifecycle_jira_calls, []) ++ [{tool, args}])

      snapshot =
        case tool do
          "jira_transition_issue" ->
            assert args["transition_id"] == "11"
            Map.put(snapshot, "status", "In Dev")

          "jira_update_factory_labels" ->
            labels = Enum.uniq((snapshot["labels"] -- args["remove_labels"]) ++ args["add_labels"])
            Map.put(snapshot, "labels", labels)

          "jira_add_comment" ->
            Process.put(:lifecycle_jira_pre_write, snapshot)
            id = "comment-#{length(snapshot["comments"] || []) + 1}"

            snapshot
            |> Map.update!("comments", &(&1 ++ [%{"id" => id, "text" => args["body"]}]))
            |> Map.put("updated", "2026-10-07T12:00:#{String.pad_leading(to_string(length(snapshot["comments"] || [])), 2, "0")}Z")
        end

      Process.put(:lifecycle_jira, snapshot)
      {:ok, %{"acknowledged" => true}}
    end
  end

  defmodule MrReader do
    @moduledoc false
    import ExUnit.Assertions

    def catalog(opts) do
      assert opts[:mcp_session] == %{thread_id: "controller-thread"}
      assert opts[:workspace] == Process.get(:lifecycle_mr_cwd)
      fields = %{"project_id" => %{"type" => "string"}, "merge_request_iid" => %{"type" => "string"}, "include_summaries" => %{"type" => "boolean"}}

      {:ok,
       %{
         "get_merge_request" => %{
           "name" => "get_merge_request",
           "annotations" => %{"readOnlyHint" => true},
           "inputSchema" => %{"type" => "object", "properties" => fields, "required" => ~w(project_id merge_request_iid)}
         }
       }}
    end

    def call("get_merge_request", args, _opts) do
      assert args["project_id"] == "1000" and args["merge_request_iid"] == "1"
      {:ok, Process.get(:lifecycle_mr)}
    end
  end

  defmodule WorkerServer do
    @moduledoc false
    alias SymphonyElixir.Factory.TicketChatCommands

    def start_session(workspace, opts) do
      thread = opts[:resume_thread_id] || "role-#{System.unique_integer([:positive])}"
      opts[:on_thread_created].(thread)

      {:ok,
       %{
         thread_id: thread,
         workspace: workspace,
         worker_policy: TicketWorkerRunner.policy(opts[:worker_access], workspace),
         worker_invocation: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
         model: opts[:model],
         reasoning_effort: opts[:reasoning_effort],
         files: opts[:worker_files],
         dynamic_tool_binding: %{tool_specs: WorkerFileTools.tool_specs()},
         metadata: %{codex_app_server_pid: "fixture"}
       }}
    end

    def run_turn(session, prompt, _issue, opts) do
      packet = Jason.decode!(prompt)
      turn = "turn-#{System.unique_integer([:positive])}"
      if session.files, do: :ok = WorkerFileTools.turn_preflight(session.files, session)
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})
      output = output(session, packet, turn) |> structured_report(packet)

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "threadId" => session.thread_id,
            "turnId" => turn,
            "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}
          }
        }
      })

      {:ok, %{turn_id: turn}}
    end

    defp structured_report(output, packet) do
      base = packet["base_packet"] || packet

      case base["review_protocol"] do
        nil ->
          output

        protocol ->
          rows = fn ids, status -> Enum.map(ids, &%{"id" => &1, "status" => status, "evidence" => ["Synthetic fixture boundary observation"]}) end

          report = %{
            "version" => protocol["version"],
            "candidate_sha" => base["candidate_sha"] || base["base_sha"],
            "block_reason" => "NONE",
            "criteria" => rows.(protocol["criterion_ids"], "PASS"),
            "closures" => rows.(Enum.map(protocol["finding_obligations"], & &1["id"]), "ADDRESSED"),
            "boundary_sweeps" => Enum.map(rows.(protocol["criterion_ids"], "CHECKED"), &Map.put(&1, "paths", ["fixture.txt"])),
            "finding_classifications" => []
          }

          if protocol["version"] == 2 do
            output
            |> Map.delete("findings")
            |> Map.put(
              "review_report",
              report |> Map.delete("finding_classifications") |> Map.put("findings", []) |> Map.put("affected_path_checks", rows.(protocol["review_scope"]["affected_paths"] || [], "CHECKED"))
            )
          else
            Map.put(output, "review_report", report)
          end
      end
    end

    defp output(_session, %{"role" => "feature-planner"}, _turn) do
      plan = if Application.get_env(:symphony_elixir, :lifecycle_writer_mode) == :blocked, do: "blocked", else: "Implement the fixture in two passes."
      %{"status" => "PLANNED", "plan_markdown" => plan, "blockers" => []}
    end

    defp output(_session, %{"role" => "change-verifier", "candidate_sha" => sha}, _turn),
      do: %{"status" => "PASS", "candidate_sha" => sha, "findings" => [], "checks" => ["fixture review"]}

    defp output(_session, %{"role" => "feature-writer", "plan" => "no-op"}, _turn) do
      if Application.get_env(:symphony_elixir, :lifecycle_writer_mode) == :blocked do
        %{
          "status" => "BLOCKED",
          "summary" => "The fixture requires a decision before editing.",
          "changed_paths" => [],
          "commit_message" => nil,
          "blockers" => ["Fixture decision unresolved"],
          "checks" => ["NOT_RUN: no source changes"],
          "remaining_criteria" => ["Fixture behavior"],
          "next_slice" => "Wait for the fixture decision."
        }
      else
        %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => ["NOT_RUN: controller checks pending"]}
      end
    end

    defp output(session, %{"role" => "feature-writer", "plan" => "file-io-blocked"} = packet, turn) do
      session
      |> output_source_slice(packet, turn)
      |> Map.merge(%{"status" => "BLOCKED", "commit_message" => nil, "blockers" => ["file_worker_helper_exit_unproven; file_worker_edit_reconciliation_required"]})
    end

    defp output(session, %{"controller_infrastructure_recovery" => key, "base_packet" => packet}, turn) when is_binary(key),
      do: output_source_slice(session, packet, turn)

    defp output(session, %{"controller_failed_turn_recovery" => key, "base_packet" => packet}, turn) when is_binary(key),
      do: output_source_slice(session, packet, turn)

    defp output(_session, %{"role" => "feature-writer", "plan" => "blocked"}, _turn),
      do: %{
        "status" => "BLOCKED",
        "summary" => "The fixture requires a decision before editing.",
        "changed_paths" => [],
        "commit_message" => nil,
        "blockers" => ["Fixture decision unresolved"],
        "checks" => ["NOT_RUN: no source changes"],
        "remaining_criteria" => ["Fixture behavior"],
        "next_slice" => "Wait for the fixture decision."
      }

    defp output(session, %{"base_packet" => %{"role" => "feature-writer"}, "explicit_native_rework" => body, "blocked_writer_context" => disposition}, turn) do
      identity = %{"threadId" => session.thread_id, "turnId" => turn, "callId" => turn <> ":resume-read", "namespace" => nil, "tool" => "repo_read"}
      read = WorkerFileTools.execute(session.files, "repo_read", %{"path" => "fixture.txt", "start_line" => 1}, identity)
      true = read["success"]
      observed = hd(read["contentItems"])["text"] |> Jason.decode!()
      true = TicketChatCommands.rework_body?(body) or String.ends_with?(body, "Rework: current candidate")
      true = is_binary(disposition["disposition_key"])
      untracked_path = Path.join(session.workspace, "untracked-resume-fixture.txt")

      changed_paths =
        if File.exists?(untracked_path) do
          true = observed["text"] == "fixture dirty state\n"
          true = File.read!(untracked_path) == "preserve for resume\n"
          ["fixture.txt", "untracked-resume-fixture.txt"]
        else
          write_identity = %{identity | "callId" => turn <> ":resume-write", "tool" => "repo_write"}

          write =
            WorkerFileTools.execute(
              session.files,
              "repo_write",
              %{"path" => "fixture.txt", "expected_sha256" => observed["sha256"], "content" => "first-writer resumed source\n"},
              write_identity
            )

          true = write["success"]
          ["fixture.txt"]
        end

      %{
        "status" => "COMPLETE",
        "changed_paths" => changed_paths,
        "commit_message" => "feat(PPL-123): continue the blocked fixture slice",
        "blockers" => [],
        "checks" => ["NOT_RUN: controller checks pending"]
      }
    end

    defp output(session, %{"role" => "feature-writer", "direct_ticket_rework" => _body}, turn) do
      if Application.get_env(:symphony_elixir, :lifecycle_writer_mode) == :edited do
        identity = %{"threadId" => session.thread_id, "turnId" => turn, "callId" => turn <> ":direct-rework-read", "namespace" => nil, "tool" => "repo_read"}
        read = WorkerFileTools.execute(session.files, "repo_read", %{"path" => "fixture.txt", "start_line" => 1}, identity)
        true = read["success"]
        observed = hd(read["contentItems"]) |> Map.fetch!("text") |> Jason.decode!()
        identity = %{identity | "callId" => turn <> ":direct-rework-write", "tool" => "repo_write"}

        write =
          WorkerFileTools.execute(
            session.files,
            "repo_write",
            %{"path" => "fixture.txt", "expected_sha256" => observed["sha256"], "content" => "edited direct READY rework\n"},
            identity
          )

        true = write["success"]

        %{
          "status" => "COMPLETE",
          "changed_paths" => ["fixture.txt"],
          "commit_message" => "feat(PPL-123): edit direct READY rework",
          "blockers" => [],
          "checks" => ["NOT_RUN: controller checks pending"]
        }
      else
        %{"status" => "COMPLETE", "changed_paths" => [], "commit_message" => nil, "blockers" => [], "checks" => ["NOT_RUN: controller checks pending"]}
      end
    end

    defp output(session, packet, turn) do
      if packet["role"] == "feature-writer" and is_binary(packet["candidate_sha"]) and
           Application.get_env(:symphony_elixir, :lifecycle_writer_mode) == :blocked do
        blocked_writer_output()
      else
        output_source_slice(session, packet, turn)
      end
    end

    defp output_source_slice(session, packet, turn) do
      content =
        cond do
          packet["plan"] == "whitespace" -> "bad \n"
          packet["plan"] == "repair" -> "repaired\n"
          is_nil(packet["candidate_sha"]) -> "first\n"
          true -> "second\n"
        end

      identity = %{"threadId" => session.thread_id, "turnId" => turn, "callId" => turn <> ":read", "namespace" => nil, "tool" => "repo_read"}
      read = WorkerFileTools.execute(session.files, "repo_read", %{"path" => "fixture.txt", "start_line" => 1}, identity)
      true = read["success"]
      sha = read["contentItems"] |> hd() |> Map.fetch!("text") |> Jason.decode!() |> Map.fetch!("sha256")
      identity = %{identity | "tool" => "repo_write", "callId" => turn <> ":write"}
      write = WorkerFileTools.execute(session.files, "repo_write", %{"path" => "fixture.txt", "expected_sha256" => sha, "content" => content}, identity)
      true = write["success"]

      %{
        "status" => if(is_nil(packet["candidate_sha"]), do: "CONTINUE", else: "COMPLETE"),
        "changed_paths" => ["fixture.txt"],
        "commit_message" => "feat(PPL-123): #{String.trim(content)} slice",
        "blockers" => [],
        "checks" => ["NOT_RUN: controller checks pending"]
      }
    end

    defp blocked_writer_output do
      %{
        "status" => "BLOCKED",
        "summary" => "The fixture requires a decision before editing.",
        "changed_paths" => [],
        "commit_message" => nil,
        "blockers" => ["Fixture decision unresolved"],
        "checks" => ["NOT_RUN: no source changes"],
        "remaining_criteria" => ["Fixture behavior"],
        "next_slice" => "Wait for the fixture decision."
      }
    end

    def stop_session(session) do
      {:ok,
       %{
         "transport" => "owned_app_server",
         "thread_id" => session.thread_id,
         "pid" => "fixture",
         "invocation_nonce" => session.worker_invocation,
         "exit_status" => 0,
         "cwd" => session.workspace
       }}
    end
  end

  defmodule ReusedTurnWorkerServer do
    @moduledoc false

    def start_session(workspace, opts), do: WorkerServer.start_session(workspace, opts)

    def run_turn(session, _prompt, _issue, opts) do
      turn = "reused-turn"

      output = %{
        "status" => "BLOCKED",
        "summary" => "The fixture requires a decision before editing.",
        "changed_paths" => [],
        "commit_message" => nil,
        "blockers" => ["Fixture decision unresolved"],
        "checks" => ["NOT_RUN: no source changes"],
        "remaining_criteria" => ["Fixture behavior"],
        "next_slice" => "Wait for the fixture decision."
      }

      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "threadId" => session.thread_id,
            "turnId" => turn,
            "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}
          }
        }
      })

      {:ok, %{turn_id: turn}}
    end

    def stop_session(session), do: WorkerServer.stop_session(session)
  end

  defmodule RejectedResumeServer do
    @moduledoc false
    def start_session(_workspace, opts),
      do: {:error, {:response_error, %{"code" => -32600, "message" => "thread #{opts[:resume_thread_id]} already has an active writer"}}}

    def run_turn(_session, _prompt, _issue, _opts), do: raise("a rejected resume must not start a turn")
    def stop_session(_session), do: raise("a rejected resume has no session")
  end

  defmodule WrongResumeThreadServer do
    @moduledoc false

    def start_session(workspace, opts),
      do: WorkerServer.start_session(workspace, Keyword.put(opts, :resume_thread_id, "foreign-thread"))

    def run_turn(session, prompt, issue, opts), do: WorkerServer.run_turn(session, prompt, issue, opts)
    def stop_session(session), do: WorkerServer.stop_session(session)
  end

  defmodule WrongResultThreadServer do
    @moduledoc false

    def start_session(workspace, opts), do: WorkerServer.start_session(workspace, opts)

    def run_turn(session, _prompt, _issue, opts) do
      turn = "new-resume-turn"
      output = %{"status" => "BLOCKED", "summary" => "Untrusted wrong-thread result.", "changed_paths" => [], "commit_message" => nil, "blockers" => ["fixture"], "checks" => []}
      opts[:on_message].(%{event: :session_started, thread_id: session.thread_id, turn_id: turn})

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "threadId" => "foreign-thread",
            "turnId" => turn,
            "item" => %{"id" => "final", "type" => "agentMessage", "text" => Jason.encode!(output)}
          }
        }
      })

      {:ok, %{turn_id: turn}}
    end

    def stop_session(session), do: WorkerServer.stop_session(session)
  end

  defmodule HeldResumeWorkerServer do
    @moduledoc false

    def start_session(workspace, opts) do
      case opts[:resume_thread_id] do
        thread when is_binary(thread) ->
          :ets.update_counter(:ticket_resume_start_counter, :count, {2, 1}, {:count, 0})
          true = :ets.insert(:ticket_resume_start_counter, {:starter, self()})
          send(Process.whereis(:ticket_resume_start_owner), {:ticket_resume_start_sent, thread, self()})

          receive do
            :continue_ticket_resume -> WorkerServer.start_session(workspace, opts)
          after
            60_000 -> {:error, :ticket_resume_fixture_wait_expired}
          end

        _ ->
          WorkerServer.start_session(workspace, opts)
      end
    end

    def run_turn(session, prompt, issue, opts), do: WorkerServer.run_turn(session, prompt, issue, opts)
    def stop_session(session), do: WorkerServer.stop_session(session)
  end

  def mr_guard(request) do
    at = DateTime.to_iso8601(DateTime.utc_now())
    metadata = Jason.decode!(request["metadata_json"])
    previous_turn_id = metadata["previous_turn_id"]
    raw = %{"data" => [], "nextCursor" => nil}
    latest = %{"data" => [%{"id" => previous_turn_id, "status" => "completed", "items" => []}], "nextCursor" => nil}
    digest = fn value -> Base.encode16(:crypto.hash(:sha256, Jason.encode!(value)), case: :lower) end

    %{
      "source_thread_id" => Process.get(:lifecycle_broker_thread_id, "00000000-0000-0000-0000-000000000001"),
      "owner" => %{
        "source" => "codex_app/read_thread",
        "observed_at" => at,
        "response" => %{"schemaVersion" => 1, "thread" => %{"id" => request["existing_thread_id"], "cwd" => request["cwd"], "kind" => "codex", "hostId" => "local", "status" => %{"type" => "idle"}}}
      },
      "native" => %{
        "id" => request["existing_thread_id"],
        "cwd" => request["cwd"],
        "projectId" => request["codex_project_id"],
        "updatedAt" => 42,
        "queue_observation" => %{
          "thread_id" => request["existing_thread_id"],
          "empty_complete" => true,
          "count_lower_bound" => 0,
          "has_more" => false,
          "observed_at" => at,
          "raw_response" => raw,
          "sha256" => digest.(raw)
        },
        "latest_turn_observation" => %{
          "mode" => "LATEST_DESC",
          "parameters" => %{"threadId" => request["existing_thread_id"], "limit" => 1, "sortDirection" => "desc", "itemsView" => "full"},
          "raw_response" => latest,
          "sha256" => digest.(latest),
          "confirmation" => %{"raw_response" => latest, "sha256" => digest.(latest), "observed_at" => at},
          "updated_at" => 42,
          "observed_at" => at
        }
      }
    }
  end
end
