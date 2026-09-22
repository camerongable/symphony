defmodule Mix.Tasks.Factory do
  use Mix.Task

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.Admin
  alias SymphonyElixir.Workflow

  @shortdoc "Inspect, activate, or pause the local factory controller"

  @moduledoc """
  Manages the local SQLite-backed factory controller without using Jira.

      mix factory status --workflow /path/to/WORKFLOW.md
      mix factory activate --workflow /path/to/WORKFLOW.md
      mix factory pause --workflow /path/to/WORKFLOW.md

  `--dispatcher-id` is optional and defaults to the identity configured in the
  workflow. Status is read-only. Activate and pause fail while a live tick lease
  is held.
  """

  @switches [workflow: :string, dispatcher_id: :string, help: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, actions, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] or length(actions) != 1 ->
        Mix.raise("Invalid arguments.\n\n#{@moduledoc}")

      true ->
        workflow_path = Path.expand(opts[:workflow] || "WORKFLOW.md")
        factory = load_factory!(workflow_path)
        result = run_action!(List.first(actions), factory, opts[:dispatcher_id])
        Mix.shell().info(Jason.encode!(result, pretty: true))
    end
  end

  defp load_factory!(workflow_path) do
    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, settings} <- Schema.parse(workflow.config) do
      settings.factory
    else
      {:error, reason} -> Mix.raise("Unable to load factory workflow: #{inspect(reason)}")
    end
  end

  defp run_action!("status", factory, _dispatcher_id), do: unwrap!(Admin.status(factory))
  defp run_action!("activate", factory, dispatcher_id), do: unwrap!(Admin.activate(factory, dispatcher_id))
  defp run_action!("pause", factory, dispatcher_id), do: unwrap!(Admin.pause(factory, dispatcher_id))
  defp run_action!(action, _factory, _dispatcher_id), do: Mix.raise("Unknown factory action: #{action}")

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Mix.raise("Factory operation failed: #{inspect(reason)}")
end
