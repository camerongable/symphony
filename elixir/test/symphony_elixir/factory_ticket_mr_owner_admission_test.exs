defmodule SymphonyElixir.FactoryTicketMrOwnerAdmissionTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.{BrokerRuntime, DesktopRequest, TicketMrOwnerAdmission}

  test "caller maps and copied process dictionaries cannot supply service authority" do
    forged = %TicketMrOwnerAdmission{authority: make_ref(), factory: %{database: Path.join(System.tmp_dir!(), "mr-owner-unregistered/factory.sqlite")}}
    Process.put({BrokerRuntime, :owner_admission}, forged)
    on_exit(fn -> Process.delete({BrokerRuntime, :owner_admission}) end)
    refute BrokerRuntime.owner_admission_active?(forged)
    refute BrokerRuntime.owner_admission_active?(%{})
    assert {:error, :mr_owner_service_authority_required} = TicketMrOwnerAdmission.finalize(nil, forged, forged.factory, %{})
    assert {:error, :mr_owner_service_authority_required} = DesktopRequest.claim_mr_prequalified(nil, forged, %{})
  end
end
