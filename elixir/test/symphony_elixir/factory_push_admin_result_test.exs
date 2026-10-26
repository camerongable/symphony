defmodule SymphonyElixir.FactoryPushAdminResultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Admin

  for status <- ~w(INPUT_RETIREMENT_PREPARED INPUT_NOT_ISSUED_RETIRED UNATTACHED_RETIREMENT_PREPARED UNATTACHED_PUSH_RETIRED PREISSUANCE_RETIREMENT_PREPARED PREISSUANCE_PUSH_RETIRED) do
    test "#{status} preserves the complete recovery response without a run record" do
      result = %{status: unquote(status), run_id: "run", successor_nonce: "successor", plan_sha256: "plan", original_outcome: "GIT_NOT_ISSUED"}
      assert {:ok, ^result} = Admin.push_recovery_result({:ok, result}, "run")
    end
  end

  test "ordinary push preparation keeps its previous unknown-outcome response" do
    assert {:ok, %{status: "PUSH_RECOVERY_PREPARED", run_id: "run", owner_nonce: "nonce", recovery_attempt: 2, old_outcome: "UNKNOWN"}} =
             Admin.push_recovery_result({:ok, %{"owner_nonce" => "nonce", "recovery_attempt" => 2}}, "run")
  end

  test "ordinary reconciliation keeps its existing bounded state response" do
    assert {:ok, %{status: "PUSH_RECONCILED", run_id: "run", state: "CI_WAITING", old_outcome: "PUSHED", new_exit_code: 0}} =
             Admin.push_recovery_result({:ok, %{status: "PUSH_RECONCILED", run: %{"state" => "CI_WAITING"}, old_outcome: "PUSHED", new_exit_code: 0, hidden: true}}, "run")
  end

  test "recovery refusal is returned unchanged" do
    assert {:error, :unattached_retirement_already_applied_or_unproven} =
             Admin.push_recovery_result({:error, :unattached_retirement_already_applied_or_unproven}, "run")
  end
end
