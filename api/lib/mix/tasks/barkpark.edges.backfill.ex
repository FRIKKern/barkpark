defmodule Mix.Tasks.Barkpark.Edges.Backfill do
  @moduledoc """
  One-shot content-graph backfill: sweep every `(dataset, workspace)` scope's
  PUBLISHED paper corpus through `Projector.rebuild_scope/3`, materialising the
  body-walk edges (valueref / wikilink → content_edges, wire §7.6) for papers
  that predate the extractor. Projection is save-event-driven, so a
  pre-existing paper carries ZERO valueref edges until it is re-touched — this
  task touches them all once.

  ## Safe by default

  A bare invocation is a DRY RUN — it lists each scope's corpus, projects
  PURELY (no writes), and reports the per-scope doc + edge counts.
  Pass `--apply` to actually rebuild.

      # report only (writes nothing) — the safe default
      mix barkpark.edges.backfill
      mix barkpark.edges.backfill --dry-run

      # rebuild every scope's edges
      mix barkpark.edges.backfill --apply

      # narrow to one dataset / other corpus types
      mix barkpark.edges.backfill --apply --dataset production
      mix barkpark.edges.backfill --apply --types paper,task

  Idempotent (`rebuild_scope` atomically swaps each corpus's outbound edges) and
  tenancy fail-closed (a nil-workspace scope in a multi-tenant install is
  skipped and reported, mirroring `ProjectorWorker`).
  """
  @shortdoc "Backfill body-walk content edges for pre-existing papers (dry-run by default; --apply to write)"

  use Mix.Task

  alias Barkpark.EdgeProjector.Backfill

  @switches [dry_run: :boolean, apply: :boolean, dataset: :string, types: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    # Safe default: write ONLY when --apply is explicitly given (and not negated
    # by --dry-run). Any other combination is a dry run.
    dry_run? = not (Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false))

    run_opts =
      [dry_run: dry_run?]
      |> maybe_put(:dataset, Keyword.get(opts, :dataset))
      |> maybe_put(:types, parse_types(Keyword.get(opts, :types)))

    {:ok, stats} = Backfill.run(run_opts)

    Backfill.log_report(stats, fn line -> Mix.shell().info(line) end)

    if dry_run? do
      Mix.shell().info("\nDry run — nothing was written. Re-run with --apply to write.")
    end
  end

  defp parse_types(nil), do: nil

  defp parse_types(csv) when is_binary(csv) do
    case csv |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      types -> types
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
