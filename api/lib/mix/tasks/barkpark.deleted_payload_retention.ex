defmodule Mix.Tasks.Barkpark.DeletedPayloadRetention do
  @moduledoc """
  Census and manual sweep for deleted-content payloads in `mutation_events` and
  `webhook_deliveries` (owner ruling #33). Policy:
  `Barkpark.Content.DeletedPayloadRetention`.

  A bare invocation is a DRY RUN. It prints, per table, how many rows a sweep
  would redact and the oldest and newest `inserted_at` among them, and writes
  nothing. `--apply` redacts them in bounded batches, then prints the census
  again.

      mix barkpark.deleted_payload_retention              # census only
      mix barkpark.deleted_payload_retention --days 120   # census, other window
      mix barkpark.deleted_payload_retention --apply      # redact

  `--apply` does not need the scheduled sweep's switch
  (`:deleted_payload_retention, enabled:`); running it is the operator's
  explicit decision. `--batch-size N` sets rows per statement (default 1000).
  """
  @shortdoc "Census of deleted-content payloads past retention (dry run by default; --apply to redact)"

  use Mix.Task

  alias Barkpark.Content.DeletedPayloadRetention, as: Retention

  @switches [apply: :boolean, dry_run: :boolean, days: :integer, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    # Narrowed boot (no Endpoint, no Oban, no seeders): see Barkpark.OneShot.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    if (days = opts[:days]) && days < 0, do: Mix.raise("--days must be 0 or more")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)
    sweep_opts = Keyword.take(opts, [:days, :batch_size])

    report(Retention.census(sweep_opts))

    if apply? do
      {:ok, result} = Retention.sweep(sweep_opts)

      Mix.shell().info(
        "\nRedacted #{result.mutation_events} mutation_events and " <>
          "#{result.webhook_deliveries} webhook_deliveries payload(s) in #{result.passes} pass(es)."
      )

      Mix.shell().info("\nAfter:")
      report(Retention.census(sweep_opts))
    else
      Mix.shell().info("\nDry run — nothing was written. Re-run with --apply to redact.")
    end
  end

  defp report(census) do
    shell = Mix.shell()

    shell.info(
      "Deleted-content payloads older than #{census.days} day(s) " <>
        "(before #{DateTime.to_iso8601(census.cutoff)}), scheduled sweep " <>
        if(Retention.enabled?(), do: "ENABLED", else: "disabled") <> ":"
    )

    for table <- [:mutation_events, :webhook_deliveries] do
      %{count: count, oldest: oldest, newest: newest} = Map.fetch!(census, table)

      shell.info(
        "  #{table}: #{count} row(s)" <>
          if(count > 0, do: ", oldest #{iso(oldest)}, newest #{iso(newest)}", else: "")
      )
    end
  end

  defp iso(nil), do: "-"
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
