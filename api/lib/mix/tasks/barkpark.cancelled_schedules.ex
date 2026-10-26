defmodule Mix.Tasks.Barkpark.CancelledSchedules do
  @moduledoc """
  Census and manual purge of cancelled schedules past retention
  (task-44cfe871ea0edc30). Policy: `Barkpark.Content.CancelledScheduleRetention`.

  A bare invocation is a DRY RUN. It prints how many cancelled schedules a
  sweep would delete and the oldest and newest `completed_at` among them, and
  writes nothing. `--apply` deletes them in bounded batches, then prints the
  census again.

      mix barkpark.cancelled_schedules              # census only
      mix barkpark.cancelled_schedules --days 60    # census, other window
      mix barkpark.cancelled_schedules --apply      # delete

  `--apply` does not need the scheduled sweep's switch
  (`:cancelled_schedule_retention, enabled:`); running it is the operator's
  explicit decision. `--batch-size N` sets rows per statement (default 1000).
  """
  @shortdoc "Census of cancelled schedules past retention (dry run by default; --apply to delete)"

  use Mix.Task

  alias Barkpark.Content.CancelledScheduleRetention, as: Retention

  @switches [apply: :boolean, dry_run: :boolean, days: :integer, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    # Narrowed boot (no Endpoint, no Oban, no seeders): see Barkpark.OneShot.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")
    if (days = opts[:days]) && days < 0, do: Mix.raise("--days must be 0 or more")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)
    sweep_opts = Keyword.take(opts, [:days, :batch_size])

    report(Retention.census(sweep_opts))

    if apply? do
      {:ok, result} = Retention.sweep(sweep_opts)

      Mix.shell().info(
        "\nDeleted #{result.deleted} cancelled schedule(s) in #{result.passes} pass(es)."
      )

      Mix.shell().info("\nAfter:")
      report(Retention.census(sweep_opts))
    else
      Mix.shell().info("\nDry run — nothing was written. Re-run with --apply to delete.")
    end
  end

  defp report(census) do
    Mix.shell().info(
      "Cancelled schedules older than #{census.days} day(s) " <>
        "(before #{DateTime.to_iso8601(census.cutoff)}), scheduled sweep " <>
        if(Retention.enabled?(), do: "ENABLED", else: "disabled") <>
        ": #{census.count}" <>
        if(census.count > 0, do: " (#{census.oldest} .. #{census.newest})", else: "")
    )
  end
end
