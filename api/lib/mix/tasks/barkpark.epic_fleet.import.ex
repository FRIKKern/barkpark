defmodule Mix.Tasks.Barkpark.EpicFleet.Import do
  @moduledoc """
  Verify and import one canonical EpicFleet benchmark artifact.

      mix barkpark.epic_fleet.import path/to/benchmark.json
      cat benchmark.json | mix barkpark.epic_fleet.import -
  """

  use Mix.Task

  @shortdoc "Import one verified EpicFleet benchmark artifact"

  @impl Mix.Task
  def run(args) do
    path =
      case args do
        [path] -> path
        _ -> Mix.raise("usage: mix barkpark.epic_fleet.import <path|->")
      end

    refuse_unless_enabled!()
    json = if path == "-", do: IO.read(:stdio, :eof), else: File.read!(path)
    Mix.Task.run("app.start")

    case Barkpark.EpicFleet.import_benchmark_json(json) do
      {:ok, %{experiment: experiment, attempts: attempts}} ->
        Mix.shell().info("imported experiment=#{experiment.experiment_id} attempts=#{attempts}")

      {:error, reason} ->
        Mix.raise("EpicFleet benchmark import failed: #{inspect(reason)}")
    end
  end

  # task-71ea7ca2c8fabce2: an operator who switched EpicFleet off gets a named
  # refusal before the task reads its input, boots the app or writes the
  # ledger. `app.config` loads config/runtime.exs, where
  # BARKPARK_CAPABILITIES_OFF is read.
  defp refuse_unless_enabled! do
    Mix.Task.run("app.config")

    unless Barkpark.Capability.enabled?(:epic_fleet) do
      Mix.raise(
        "EpicFleet benchmark import refused: " <> Barkpark.Capability.off_message(:epic_fleet)
      )
    end
  end
end
