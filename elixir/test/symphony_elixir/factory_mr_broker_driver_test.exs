defmodule SymphonyElixir.FactoryMrBrokerDriverTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.TicketMrBrokerDriver
  @harness Path.expand("../support/mr_broker_driver_harness.js", __DIR__)

  test "released driver consumes the compact contract once without requiring raw request fields" do
    result = run(%{})
    assert result["result"]["status"] == "MR_SEND_RETURNED"
    assert result["counts"] == %{"prepare" => 1, "finalize" => 1, "read" => 2, "send" => 1}
  end

  test "preflight and correction never send" do
    assert %{"result" => %{"status" => "MR_ORCHESTRATION_PREFLIGHT_PASS"}, "counts" => %{"prepare" => 0, "finalize" => 0, "send" => 0}} = run(%{mode: "preflight"})
    assert %{"result" => %{"status" => "MR_ACTOR_CWD_CORRECTED"}, "counts" => %{"prepare" => 1, "finalize" => 1, "send" => 0}} = run(%{mode: "correct"})
  end

  test "capabilities owner and expiry refuse before committed claim or send" do
    for {scenario, prepares, error} <- [
          {"missing_send_tool", 0, "MR_ORCHESTRATION_CAPABILITY_UNAVAILABLE"},
          {"wrong_owner", 0, "OWNING_TARGET_MISMATCH"},
          {"expired", 1, "MR_ADMISSION_BUDGET_EXHAUSTED"}
        ] do
      result = run(%{scenario: scenario})
      assert result["error"] == error
      assert result["counts"]["prepare"] == prepares
      assert result["counts"]["finalize"] == 0
      assert result["counts"]["send"] == 0
    end
  end

  test "committed output mismatch stays uncertain without issuance" do
    for scenario <- ~w(wrong_target wrong_prompt wrong_model wrong_effort extra_argument extra_row_field missing_key) do
      result = run(%{scenario: scenario})
      assert result["error"] == "COMMITTED_CLAIM_OUTPUT_INVALID", scenario
      assert result["counts"]["finalize"] == 1
      assert result["counts"]["send"] == 0
    end
  end

  test "transport loss and send rejection never retry" do
    result = run(%{scenario: "lost_finalize"})
    assert result["error"] == "CLI_OBSERVATION_UNCERTAIN"
    assert result["counts"]["finalize"] == 1
    assert result["counts"]["send"] == 0
    result = run(%{scenario: "send_error"})
    assert result["error"] == "SEND_RESULT_UNCERTAIN"
    assert result["counts"]["send"] == 1
    assert result["counts"]["finalize"] == 1
  end

  test "a named reader refusal is not mislabeled transport uncertainty and never sends" do
    assert %{"error" => "MR_OWNER_ADMISSION_UNAVAILABLE", "counts" => %{"prepare" => 1, "finalize" => 1, "send" => 0}} = run(%{scenario: "reader_rejected"})
  end

  test "recovery consumes one compact grant and transport loss never reparses or retries it" do
    issued = request() |> Map.put("status", "FOLLOWUP_UNCERTAIN") |> Map.put("claimed_at", "2026-10-20T08:34:13.866648Z")
    assert %{"result" => %{"status" => "MR_SEND_RETURNED"}, "counts" => %{"prepare" => 1, "finalize" => 1, "send" => 1}} = run(%{mode: "recover", request: issued})
    assert %{"error" => "CLI_OBSERVATION_UNCERTAIN", "counts" => %{"prepare" => 1, "finalize" => 1, "send" => 0}} = run(%{mode: "recover", request: issued, scenario: "lost_finalize"})
    assert %{"error" => "SEND_RESULT_UNCERTAIN", "counts" => %{"prepare" => 1, "finalize" => 1, "send" => 1}} = run(%{mode: "recover", request: issued, scenario: "send_error"})
    assert %{"error" => "OWNING_SOURCE_ACTIVE_UNPROVEN", "counts" => %{"prepare" => 0, "finalize" => 0, "send" => 0}} = run(%{mode: "recover", request: issued, scenario: "source_interrupted"})
  end

  test "claim response transport budget refuses before preparation at exact ASCII and Unicode boundaries" do
    for character <- ["a", "é", "😀", <<127>>] do
      request = request()
      base_size = response_ascii_bytes(request)
      per_character = response_ascii_bytes(Map.update!(request, "prompt", &(&1 <> character))) - base_size
      padding = div(8192 - 512 - base_size, per_character)
      bounded = Map.update!(request, "prompt", &(&1 <> String.duplicate(character, padding)))
      assert response_ascii_bytes(bounded) + 512 <= 8192
      assert %{"result" => %{"status" => "MR_SEND_RETURNED"}} = run(%{request: bounded})
      rejected = Map.update!(bounded, "prompt", &(&1 <> character))
      assert response_ascii_bytes(rejected) + 512 > 8192
      assert %{"error" => "MR_CLAIM_RESPONSE_BUDGET_EXCEEDED", "counts" => %{"prepare" => 0, "finalize" => 0, "send" => 0}} = run(%{request: rejected})
    end
  end

  defp request do
    key = "desktop:" <> String.duplicate("a", 64)

    %{
      "request_key" => key,
      "target_kind" => "CONTROLLER",
      "action" => "FOLLOWUP",
      "status" => "PENDING",
      "existing_thread_id" => "00000000-0000-0000-0000-000000000002",
      "model" => "gpt-6.1-sol",
      "reasoning_effort" => "high",
      "prompt" => "Factory request ID: #{key}\n",
      "payload_sha256" => String.duplicate("b", 64),
      "metadata_json" => Jason.encode!(%{delivery_operation: %{version: 2, operation: "CREATE_OR_REUSE_DRAFT_MR"}})
    }
  end

  defp response_ascii_bytes(request) do
    response = %{
      request_key: request["request_key"],
      status: "FOLLOWUP_UNCERTAIN",
      arguments: %{threadId: request["existing_thread_id"], model: request["model"], thinking: request["reasoning_effort"], prompt: request["prompt"]}
    }

    code = "import sys,json,base64; value=json.loads(base64.b64decode(sys.argv[1])); print(len(json.dumps(value,ensure_ascii=True,indent=2).encode()))"
    {output, 0} = System.cmd("/usr/bin/python3", ["-c", code, response |> Jason.encode!() |> Base.encode64()])
    String.to_integer(String.trim(output))
  end

  defp run(options) do
    {:ok, driver} = TicketMrBrokerDriver.export()
    input = options |> Map.put(:driver, driver) |> Jason.encode!()
    {output, 0} = System.cmd(System.find_executable("node"), [@harness, Base.encode64(input)])
    Jason.decode!(output)
  end
end
