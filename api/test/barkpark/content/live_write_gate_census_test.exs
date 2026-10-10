defmodule Barkpark.Content.LiveWriteGateCensusTest do
  @moduledoc """
  Every module in `api/lib` that writes a document row with
  `Document.changeset/2` is classified here (task-348a4fbe24feede6).

  A draft-only seat may not change a live row, and kinds without a draft layer
  write their live row directly. `Barkpark.Content.LiveWriteGate` refuses those
  writes, but only where it is called. So a NEW direct writer (a new plugin's
  in-place save, say) must land in this table: either it calls the gate, or it
  says why its writes are not driven by a caller's seat. An unclassified writer
  reds the first test, and a `:gated` writer that stops calling the gate reds
  the second.

  Scope, stated: this census keys on `Document.changeset(`. A writer that
  updates `documents` through another shape (a raw `update_all`) is not seen
  here.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  @classified %{
    # Calls LiveWriteGate (or Lifecycle's publish-side gate) before writing.
    "barkpark/content/lifecycle.ex" => :gated,
    "barkpark/content/papers/block_ops.ex" => :gated,
    "barkpark/content/edges.ex" => :gated,
    # Writes `drafts.<id>` only; publishing is Lifecycle's.
    "barkpark/content/writer.ex" =>
      {:drafts_only, "every write target goes through DraftId.draft_id/1"},
    "barkpark/content/papers/proposals.ex" =>
      {:drafts_only, "a proposal writes the paper's draft row, never the live one"},
    # Derived data, recomputed from content someone already published.
    "barkpark/content/papers.ex" =>
      {:derived, "refresh_html_cache/3 rewrites the rendered-HTML cache of the stored blocks"},
    "barkpark/content/sheets.ex" =>
      {:derived,
       "a published embedder's sheet snapshot changes only when the sheet itself is published"},
    # Operator pipelines behind the `ops` permission, not a content seat.
    "barkpark/plugins/onixedit/bokbasen/status.ex" =>
      {:operator, "Bokbasen delivery status, written by the ops publish pipeline"},
    "barkpark/plugins/onixedit/web/staleness_live.ex" =>
      {:operator, "mounted on LiveAuth :ops (ops or admin token)"},
    # Migrations, backfills and seeds: no caller seat exists.
    "barkpark/content/papers/backfill_block_ids.ex" => {:system, "one-off backfill"},
    "barkpark/content/papers/composition_migration.ex" => {:system, "shape migration"},
    "barkpark/content/papers/doctrine_backfill.ex" => {:system, "one-off backfill"},
    "barkpark/seeds/demo.ex" => {:system, "seed profile"},
    "mix/tasks/frt.seed.ex" => {:system, "mix task"},
    "mix/tasks/barkpark.preview.backfill.ex" => {:system, "mix task"},
    "mix/tasks/barkpark.rehydrate_body_html.ex" => {:system, "mix task"}
  }

  defp writers do
    Path.wildcard(Path.join(@lib, "**/*.ex"))
    |> Enum.filter(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Enum.any?(&String.contains?(&1, "Document.changeset("))
    end)
    |> Enum.map(&Path.relative_to(&1, @lib))
    |> Enum.reject(&(&1 == "barkpark/content/document.ex"))
    |> Enum.sort()
  end

  test "every direct document writer is classified" do
    unclassified = writers() -- Map.keys(@classified)

    assert unclassified == [],
           "these modules write documents with Document.changeset/2 but are not in " <>
             "@classified: #{inspect(unclassified)}. If a caller's seat drives the write " <>
             "and it can land on a live (non-drafts.) row, call " <>
             "Barkpark.Content.LiveWriteGate.check/2 before it and mark it :gated."
  end

  test "every classified module still exists and still writes" do
    assert Map.keys(@classified) -- writers() == []
  end

  test "every :gated writer calls the gate" do
    for {path, :gated} <- @classified do
      source = File.read!(Path.join(@lib, path))

      assert source =~ "LiveWriteGate." or source =~ "ensure_may_publish(",
             "#{path} is classified :gated but no longer calls LiveWriteGate"
    end
  end
end
