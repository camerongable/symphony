defmodule Mix.Tasks.Factory.PilotReport do
  use Mix.Task

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.PilotReport
  alias SymphonyElixir.Workflow

  @shortdoc "Read pilot lifecycle evidence without changing the ledger"
  @moduledoc """
  Prints ledger-backed wall-clock lifecycle evidence as JSON.

      mix factory.pilot_report --issue PPL-123 --workflow /path/to/WORKFLOW.md
      mix factory.pilot_report --run RUN_ID --workflow /path/to/WORKFLOW.md

  With no filter, shows the 20 most recent runs. Token usage, human intervention
  totals and historical disk growth are explicitly unavailable, not estimated.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [workflow: :string, issue: :string, run: :string, help: :boolean])

    cond do
      opts[:help] -> Mix.shell().info(@moduledoc)
      rest != [] or invalid != [] or (opts[:issue] && opts[:run]) -> Mix.raise("Invalid arguments.\n\n#{@moduledoc}")
      true -> print_report(opts)
    end
  end

  defp print_report(opts) do
    with {:ok, workflow} <- Workflow.load(Path.expand(opts[:workflow] || "WORKFLOW.md")),
         {:ok, settings} <- Schema.parse(workflow.config),
         database when is_binary(database) <- settings.factory.database,
         true <- File.regular?(database),
         {:ok, _} <- Application.ensure_all_started(:exqlite),
         {:ok, connection} <- Exqlite.start_link(database: database, mode: :readonly) do
      try do
        connection |> PilotReport.snapshot(opts) |> Jason.encode!(pretty: true) |> Mix.shell().info()
      after
        GenServer.stop(connection)
      end
    else
      reason -> Mix.raise("Unable to read pilot ledger: #{inspect(reason)}")
    end
  end
end
