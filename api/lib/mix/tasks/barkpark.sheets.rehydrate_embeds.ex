defmodule Mix.Tasks.Barkpark.Sheets.RehydrateEmbeds do
  @moduledoc """
  One-shot backfill: re-synthesize every embedded sheet snapshot through the
  current `Barkpark.Plugins.Sheets.Core.snapshot_for/2`.

  A `{"type":"sheet","ref":…}` block caches a dense `"snapshot"` the write-through
  refreshes on every sheet save. A snapshot persisted BEFORE a synthesis change
  (e.g. the v2 stamp — `Fmt.display` value strings, so an imported 25% cell reads
  "25.00%" not "0.25", plus the truncation marker) stays stale until the sheet or
  paper happens to be re-saved. This task sweeps every `"sheet"` document once and
  runs the write-through for each, so no-longer-current embeds are rewritten.

  Idempotent: the write-through's equality gate rewrites an embedding doc ONLY
  when its cached snapshot differs from the freshly synthesized one — a second
  run reports every doc as unchanged.

      mix barkpark.sheets.rehydrate_embeds

  Reports scanned sheet count and how many embedding docs were rewritten vs left
  unchanged.
  """
  @shortdoc "Re-synthesize embedded sheet snapshots through the current synthesizer (idempotent)"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    tally = rehydrate()

    Mix.shell().info(
      "rehydrate_embeds: scanned #{tally.scanned} sheet(s) — " <>
        "#{tally.rewritten} embedding doc(s) rewritten, #{tally.noop} unchanged."
    )
  end

  @doc """
  Sweep every `"sheet"` document — one row per published root, preferring the
  DRAFT (the freshest content, mirroring `Content.Sheets.fetch_embedded_sheets/2`
  draft-wins rule) — and run the embed write-through for each. Returns a
  `%{scanned, rewritten, noop}` tally. Extracted from `run/1` so tests can call
  it inside the DB sandbox without going through `Mix.Task`.
  """
  def rehydrate do
    import Ecto.Query
    import Barkpark.Content.DraftId, only: [published_id: 1, draft?: 1]
    alias Barkpark.Content.{Document, Sheets}
    alias Barkpark.Repo

    chosen =
      from(d in Document, where: d.type == "sheet")
      |> Repo.all()
      |> Enum.reduce(%{}, fn doc, acc ->
        root = published_id(doc.doc_id)

        if draft?(doc.doc_id) or not Map.has_key?(acc, root) do
          Map.put(acc, root, doc)
        else
          acc
        end
      end)

    Enum.reduce(chosen, %{scanned: 0, rewritten: 0, noop: 0}, fn {_root, doc}, acc ->
      %{rewritten: rw, noop: np} = Sheets.refresh_sheet_embeds(doc)
      %{acc | scanned: acc.scanned + 1, rewritten: acc.rewritten + rw, noop: acc.noop + np}
    end)
  end
end
