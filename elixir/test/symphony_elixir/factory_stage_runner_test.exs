defmodule SymphonyElixir.FactoryStageRunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.{StageRunner, StageSchemas}
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAppServer do
    @spec start_session(Path.t(), keyword()) :: {:ok, map()}
    def start_session(_workspace, opts) do
      send(self(), {:start_session, opts})
      {:ok, %{thread_id: "thread-123"}}
    end

    @spec run_turn(map(), String.t(), Issue.t(), keyword()) :: {:ok, map()}
    def run_turn(_session, _prompt, _issue, opts) do
      send(self(), {:run_turn, opts[:output_schema]})

      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" => Jason.encode!(%{"status" => "PASS"})
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
    def start_session(_workspace, _opts) do
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
              "text" => Jason.encode!(%{"status" => "PASS"})
            }
          }
        }
      })

      {:ok, %{turn_id: "replacement-turn"}}
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
             output: %{"status" => "PASS"}
           }

    assert_received {:start_session, start_opts}
    assert start_opts[:thread_name] == "PPL-100 specification critic"
    assert start_opts[:fork_on_active_writer] == true
    assert start_opts[:resume_thread_id] == "existing-thread"
    assert start_opts[:model] == "gpt-test"
    assert start_opts[:project_id] == "project-grail"
    assert start_opts[:section_id] == "section-factory"
    assert start_opts[:required_mcp_servers] == ["Jira", "GitLab"]
    assert start_opts[:mcp_startup_timeout_ms] == 45_000
    assert start_opts[:reasoning_effort] == "high"
    assert start_opts[:service_name] == "symphony-factory"
    assert start_opts[:thread_source] == "symphonyFactory"
    assert_received {:thread_started, "thread-123"}
    assert_received {:run_turn, ^schema}
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

  test "schemas are strict and stage-specific" do
    writer = StageSchemas.for_stage(:feature_writer)
    verifier = StageSchemas.for_stage(:change_verifier)

    assert writer["additionalProperties"] == false
    assert writer["properties"]["status"]["enum"] == ~w(CONTINUE COMPLETE BLOCKED)
    assert verifier["properties"]["status"]["enum"] == ~w(PASS REPAIR BLOCK)
  end
end
