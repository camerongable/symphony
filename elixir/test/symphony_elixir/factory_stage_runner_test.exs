defmodule SymphonyElixir.FactoryStageRunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{Prompt, StageRunner, StageSchemas}
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAppServer do
    @spec start_session(Path.t(), keyword()) :: {:ok, map()}
    def start_session(_workspace, opts) do
      send(self(), {:start_session, opts})
      if is_function(opts[:on_thread_created], 1), do: opts[:on_thread_created].("thread-123")
      {:ok, %{thread_id: "thread-123"}}
    end

    @spec run_turn(map(), String.t(), Issue.t(), keyword()) :: {:ok, map()}
    def run_turn(_session, _prompt, _issue, opts) do
      send(self(), {:run_turn, opts[:output_schema]})

      output =
        if Process.get(:factory_test_schema_invalid, false),
          do: %{"status" => "PASS"},
          else: %{"status" => "PASS", "findings" => [], "required_questions" => []}

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" => Jason.encode!(output)
            }
          }
        }
      })

      {:ok, %{turn_id: "turn-456"}}
    end

    @spec stop_session(map()) :: :ok
    def stop_session(_session), do: :ok
  end

  defmodule FakeForkedAppServer do
    @spec start_session(Path.t(), keyword()) :: {:ok, map()}
    def start_session(_workspace, opts) do
      if is_function(opts[:on_thread_created], 1),
        do: opts[:on_thread_created].("replacement-thread")

      {:ok,
       %{
         thread_id: "replacement-thread",
         forked_from_thread_id: "superseded-thread"
       }}
    end

    @spec archive_thread(map(), String.t()) :: :ok
    def archive_thread(_session, thread_id) do
      send(self(), {:archived, thread_id})
      :ok
    end

    @spec run_turn(map(), String.t(), Issue.t(), keyword()) :: {:ok, map()}
    def run_turn(_session, _prompt, _issue, opts) do
      send(self(), :turn_started)

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" => Jason.encode!(%{"status" => "PASS", "findings" => [], "required_questions" => []})
            }
          }
        }
      })

      {:ok, %{turn_id: "replacement-turn"}}
    end

    @spec stop_session(map()) :: :ok
    def stop_session(_session), do: :ok
  end

  defmodule FakeStartupFailureAppServer do
    @spec start_session(Path.t(), keyword()) :: {:error, atom()}
    def start_session(_workspace, opts) do
      opts[:on_thread_created].("created-before-mcp-failure")
      {:error, :mcp_startup_failed}
    end
  end

  defmodule FakeMcpAppServer do
    @spec start_session(Path.t(), keyword()) :: {:ok, map()}
    def start_session(_workspace, _opts), do: {:ok, %{thread_id: "thread-mcp"}}

    @spec run_turn(map(), String.t(), Issue.t(), keyword()) :: {:ok, map()}
    def run_turn(_session, _prompt, _issue, opts) do
      server =
        if Process.get(:factory_test_nested_server, false),
          do: %{"name" => "Jira"},
          else: nil

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "mcpToolCall",
              "server" => server,
              "serverName" => "Jira",
              "toolName" => "jira_search",
              "status" => Process.get(:factory_test_mcp_status, "completed"),
              "result" => %{"isError" => Process.get(:factory_test_mcp_result_error, false)}
            }
          }
        }
      })

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" => Jason.encode!(%{"status" => "PASS", "issue_key" => "PPL-100", "snapshot_json" => "[]"})
            }
          }
        }
      })

      {:ok, %{turn_id: "turn-mcp"}}
    end

    @spec stop_session(map()) :: :ok
    def stop_session(_session), do: :ok
  end

  defmodule FakeFormattingAppServer do
    @spec start_session(Path.t(), keyword()) :: {:ok, map()}
    def start_session(_workspace, _opts), do: {:ok, %{thread_id: "thread-formatting"}}

    @spec run_turn(map(), String.t(), Issue.t(), keyword()) :: {:ok, map()}
    def run_turn(_session, prompt, _issue, opts) do
      count = Process.get(:formatting_turn_count, 0) + 1
      Process.put(:formatting_turn_count, count)
      send(self(), {:formatting_turn, count, prompt})

      text =
        if count == 1 or Process.get(:formatting_always_invalid, false) do
          "Compatibility behavior is unresolved. Question: Which compatibility behavior is required?"
        else
          Jason.encode!(%{
            "status" => "BLOCKED",
            "contract_markdown" => "",
            "questions" => ["Which compatibility behavior is required?"],
            "risk" => "unknown",
            "risk_signals" => [],
            "manual_validation_required" => false
          })
        end

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}
        }
      })

      {:ok, %{turn_id: "turn-#{count}"}}
    end

    @spec stop_session(map()) :: :ok
    def stop_session(_session), do: :ok
  end

  defmodule FakeCommentaryOnlyAppServer do
    @spec start_session(Path.t(), keyword()) :: {:ok, map()}
    def start_session(_workspace, _opts), do: {:ok, %{thread_id: "thread-commentary"}}

    @spec run_turn(map(), String.t(), Issue.t(), keyword()) :: {:ok, map()}
    def run_turn(_session, _prompt, _issue, opts) do
      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "phase" => "commentary",
              "text" => Jason.encode!(%{"status" => "PASS"})
            }
          }
        }
      })

      {:ok, %{turn_id: "turn-commentary"}}
    end

    @spec stop_session(map()) :: :ok
    def stop_session(_session), do: :ok
  end

  test "runs a named resumable task with a structured response" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:specification_critic)
    parent = self()

    assert {:ok, result} =
             StageRunner.run("/tmp/workspace", issue, "Review", schema,
               app_server: FakeAppServer,
               fork_on_active_writer: true,
               thread_name: "PPL-100 specification critic",
               resume_thread_id: "existing-thread",
               approval_policy: "on-request",
               allowed_mcp_tool_approvals: [%{server: "Jira", tool: "jira_add_comment"}],
               model: "gpt-test",
               project_id: "project-grail",
               section_id: "section-factory",
               required_mcp_servers: ["Jira", "GitLab"],
               mcp_startup_timeout_ms: 45_000,
               reasoning_effort: "high",
               on_thread_started: &send(parent, {:thread_started, &1})
             )

    assert result == %{
             thread_id: "thread-123",
             turn_id: "turn-456",
             output: %{"status" => "PASS", "findings" => [], "required_questions" => []}
           }

    assert_received {:start_session, start_opts}
    assert start_opts[:thread_name] == "PPL-100 specification critic"
    assert start_opts[:fork_on_active_writer] == true
    assert start_opts[:resume_thread_id] == "existing-thread"
    assert start_opts[:approval_policy] == "on-request"
    assert start_opts[:allowed_mcp_tool_approvals] == [%{server: "Jira", tool: "jira_add_comment"}]
    assert start_opts[:model] == "gpt-test"
    assert start_opts[:project_id] == "project-grail"
    assert start_opts[:section_id] == "section-factory"
    assert start_opts[:required_mcp_servers] == ["Jira", "GitLab"]
    assert start_opts[:mcp_startup_timeout_ms] == 45_000
    assert start_opts[:reasoning_effort] == "high"
    assert start_opts[:service_name] == "symphony-factory"
    assert start_opts[:thread_source] == "symphonyFactory"
    assert is_function(start_opts[:on_thread_created], 1)
    assert_received {:thread_started, "thread-123"}
    refute_received {:thread_started, "thread-123"}
    assert_received {:run_turn, ^schema}
  end

  test "persists a created thread before MCP startup fails so the next attempt can resume it" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:specification_author)
    parent = self()

    assert {:error, :mcp_startup_failed} =
             StageRunner.run("/tmp/workspace", issue, "Draft", schema,
               app_server: FakeStartupFailureAppServer,
               on_thread_started: &send(parent, {:thread_started, &1})
             )

    assert_received {:thread_started, "created-before-mcp-failure"}
  end

  test "archives a forked predecessor after persisting the replacement identity" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:specification_critic)
    parent = self()

    assert {:ok, result} =
             StageRunner.run("/tmp/workspace", issue, "Review", schema,
               app_server: FakeForkedAppServer,
               archive_forked_thread: true,
               on_thread_started: &send(parent, {:persisted, &1})
             )

    assert result.thread_id == "replacement-thread"
    assert_receive {:persisted, "replacement-thread"}
    assert_receive {:archived, "superseded-thread"}
    assert_receive :turn_started
  end

  test "fails closed when a required connector tool was not called" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:jira_snapshot)

    assert {:error, {:required_tool_calls_missing, [%{server: "Jira", tool: "jira_search"}]}} =
             StageRunner.run("/tmp/workspace", issue, "Read Jira", schema,
               app_server: FakeAppServer,
               required_tool_calls: [%{server: "Jira", tool: "jira_search"}]
             )
  end

  test "accepts output only after the required MCP tool completed" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:jira_snapshot)

    assert {:ok, %{output: %{"status" => "PASS", "issue_key" => "PPL-100"}}} =
             StageRunner.run("/tmp/workspace", issue, "Read Jira", schema,
               app_server: FakeMcpAppServer,
               required_tool_calls: [%{server: "jira", tool: "JIRA_SEARCH"}]
             )
  end

  test "rejects an MCP invocation without a confirmed successful result" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:jira_snapshot)
    required = [%{server: "Jira", tool: "jira_search"}]

    Process.put(:factory_test_mcp_status, nil)

    assert {:error, {:required_tool_calls_missing, ^required}} =
             StageRunner.run("/tmp/workspace", issue, "Read Jira", schema,
               app_server: FakeMcpAppServer,
               required_tool_calls: required
             )

    Process.put(:factory_test_mcp_status, "completed")
    Process.put(:factory_test_mcp_result_error, true)

    assert {:error, {:required_tool_calls_missing, ^required}} =
             StageRunner.run("/tmp/workspace", issue, "Read Jira", schema,
               app_server: FakeMcpAppServer,
               required_tool_calls: required
             )
  end

  test "recognizes a successful MCP call with a nested server name" do
    Process.put(:factory_test_nested_server, true)
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}

    assert {:ok, %{output: %{"status" => "PASS"}}} =
             StageRunner.run("/tmp/workspace", issue, "Read Jira", StageSchemas.for_stage(:jira_snapshot),
               app_server: FakeMcpAppServer,
               required_tool_calls: [%{server: "Jira", tool: "jira_search"}]
             )
  end

  test "repairs one malformed specification response in the same task without restarting work" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:specification_author)

    assert {:ok, %{thread_id: "thread-formatting", turn_id: "turn-2", output: output}} =
             StageRunner.run("/tmp/workspace", issue, "Draft", schema,
               app_server: FakeFormattingAppServer,
               format_repair_attempts: 1
             )

    assert output["status"] == "BLOCKED"
    assert_received {:formatting_turn, 1, "Draft"}
    assert_received {:formatting_turn, 2, repair_prompt}
    assert repair_prompt =~ "Do not run tools"
    assert repair_prompt =~ "Do not invent"
    refute_received {:formatting_turn, 3, _prompt}
  end

  test "does not launch a third turn when formatting-only repair also fails" do
    Process.put(:formatting_always_invalid, true)
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:specification_author)

    assert {:error, {:factory_stage_output_invalid_json, _reason}} =
             StageRunner.run("/tmp/workspace", issue, "Draft", schema,
               app_server: FakeFormattingAppServer,
               format_repair_attempts: 1
             )

    assert_received {:formatting_turn, 1, "Draft"}
    assert_received {:formatting_turn, 2, _repair_prompt}
    refute_received {:formatting_turn, 3, _prompt}
  end

  test "does not accept an interim commentary message as the stage result" do
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}
    schema = StageSchemas.for_stage(:specification_critic)

    assert {:error, :factory_stage_output_missing} =
             StageRunner.run("/tmp/workspace", issue, "Review", schema, app_server: FakeCommentaryOnlyAppServer)
  end

  test "rejects a JSON object missing required stage fields" do
    Process.put(:factory_test_schema_invalid, true)
    issue = %Issue{id: "100", identifier: "PPL-100", title: "Factory task"}

    assert {:error, :factory_stage_output_schema_mismatch} =
             StageRunner.run("/tmp/workspace", issue, "Review", StageSchemas.for_stage(:specification_critic), app_server: FakeAppServer)
  end

  test "schemas are strict and stage-specific" do
    writer = StageSchemas.for_stage(:feature_writer)
    native_writer = StageSchemas.for_stage(:native_feature_writer)
    verifier = StageSchemas.for_stage(:change_verifier)

    assert writer["additionalProperties"] == false
    assert writer["properties"]["status"]["enum"] == ~w(CONTINUE COMPLETE BLOCKED)
    assert native_writer["additionalProperties"] == false
    assert "changed_paths" in native_writer["required"]
    assert "commit_message" in native_writer["required"]
    refute "commit_sha" in native_writer["properties"]
    assert verifier["properties"]["status"]["enum"] == ~w(PASS REPAIR BLOCK)
  end

  test "native writer schema accepts the bounded skill's minimal slice manifest" do
    output = %{
      "status" => "CONTINUE",
      "changed_paths" => ["go/src/grail.com/doc-extract/server/service/ai/base/BUILD"],
      "commit_message" => "feat(PPL-9723): add PDF visual findings contract and shared parse",
      "checks" => ["Focused tests passed"],
      "blockers" => [],
      "next_slice" => "Implement bounded visual scanning"
    }

    assert :ok = StageSchemas.validate(output, StageSchemas.for_stage(:native_feature_writer))
  end

  test "native writer prompt carries the full factory route and forbids worker Git metadata writes" do
    prompt =
      Prompt.feature_writer(%{}, "contract", String.duplicate("a", 64), "plan", 2, [],
        controller_commits: true,
        run_id: "run-123",
        spec_revision: 4,
        base_ref: "origin/master",
        iteration_limit: 8
      )

    assert prompt =~ "Factory run ID: run-123"
    assert prompt =~ "Spec revision: 4"
    assert prompt =~ "Base ref: origin/master"
    assert prompt =~ "Maximum passes: 8"
    assert prompt =~ "create/switch branches, stage, or commit"
    assert prompt =~ "Return only one raw JSON object"
    assert prompt =~ "Never ask the user for approval"
    assert prompt =~ "do not call `request_permissions`"
    assert prompt =~ "If an operation is denied"
    assert prompt =~ "do not initiate an operation"
  end

  test "native change verifier reviews its provided detached checkout without creating another" do
    candidate_sha = String.duplicate("a", 40)
    prompt = Prompt.change_verifier(%{}, "contract", String.duplicate("b", 64), candidate_sha, "master")

    assert prompt =~ "reviewer mode"
    assert prompt =~ "current directory is a detached worktree"
    assert prompt =~ candidate_sha
    assert prompt =~ "Do not create another worktree"
    assert prompt =~ "Do not request sandbox or tool-permission escalation"
    refute prompt =~ "controller mode"
  end
end
