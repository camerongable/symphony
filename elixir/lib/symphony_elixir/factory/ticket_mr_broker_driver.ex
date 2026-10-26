defmodule SymphonyElixir.Factory.TicketMrBrokerDriver do
  @moduledoc "Exports the released broker orchestration program without granting issuance authority."
  alias SymphonyElixir.PathSafety

  @program Path.expand("../../../priv/ticket_mr_broker_driver_v2.js", __DIR__)
  @external_resource @program
  @sha256 @program |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  @spec export() :: {:ok, map()} | {:error, atom()}
  def export do
    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_mr_broker_driver_v2.js")),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, source} <- File.read(path),
         true <- Base.encode16(:crypto.hash(:sha256, source), case: :lower) == @sha256 do
      {:ok, %{version: 1, sha256: @sha256, source: source}}
    else
      _ -> {:error, :mr_driver_program_changed}
    end
  end
end
