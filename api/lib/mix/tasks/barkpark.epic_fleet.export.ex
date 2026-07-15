defmodule Mix.Tasks.Barkpark.EpicFleet.Export do
  @moduledoc """
  Export one durable EpicFleet benchmark as canonical JSON.

      mix barkpark.epic_fleet.export --experiment UUID [--out PATH]
  """

  use Mix.Task

  @shortdoc "Export one EpicFleet benchmark as canonical JSON"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args, strict: [experiment: :string, out: :string])

    if invalid != [], do: Mix.raise("unknown switches: #{inspect(invalid)}")

    experiment_id =
      Keyword.get(opts, :experiment) ||
        Mix.raise("usage: mix barkpark.epic_fleet.export --experiment UUID [--out PATH]")

    Mix.Task.run("app.start")

    case Barkpark.EpicFleet.export_benchmark_json(experiment_id) do
      {:ok, json} ->
        case Keyword.get(opts, :out) do
          nil ->
            IO.write(json)

          path ->
            case Barkpark.EpicFleet.write_benchmark_json_file(path, json) do
              :ok -> :ok
              {:error, reason} -> Mix.raise("atomic export failed: #{:file.format_error(reason)}")
            end
        end

      {:error, reason} ->
        Mix.raise("EpicFleet benchmark export failed: #{inspect(reason)}")
    end
  end
end
