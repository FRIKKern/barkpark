defmodule BarkparkWeb.BulldocsSheetEmbedTest do
  @moduledoc """
  End-to-end View-mode lock for the `"sheet"` embed block: a paper ingested
  with a sheet block renders an HTML grid in the Bulldocs reader, and after
  the referenced sheet is mutated through Content the write-through refreshed
  snapshot is what the reader renders — no plugin in the loop, the block
  composes straight from its cached snapshot (fresh-install invariant).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @slug "2026-06-12-sheet-embed-demo"
  @dataset "production"

  defp sheet_content(value) do
    %{
      "tabs" => [
        %{
          "frozen_rows" => 1,
          "cells" => %{
            "A1" => %{"v" => "Metric"},
            "A2" => %{"v" => value}
          }
        }
      ]
    }
  end

  test "paper embedding a sheet renders the refreshed grid in View mode", %{conn: conn} do
    {:ok, sheet} =
      Content.create_document(
        "sheet",
        %{"doc_id" => "embed-demo-sheet", "content" => sheet_content("first-value")},
        @dataset
      )

    pub_id = Content.published_id(sheet.doc_id)

    # Ingest a paper embedding the sheet. The block carries NO snapshot yet
    # (the sheet was saved before any embed existed), so the reader shows an
    # empty grid — a valid table, never a crash.
    {:ok, _paper} =
      Content.upsert_paper(%{
        slug: @slug,
        blocks: [%{"id" => "s1", "type" => "sheet", "ref" => pub_id, "tab" => 0}]
      })

    {:ok, _view, html} = live(conn, "/papers/#{@slug}")
    assert html =~ "<table"
    refute html =~ "first-value"

    # Mutate the sheet: write-through refreshes the paper's snapshot (and its
    # body_html cache) in the same logical operation.
    {:ok, _} =
      Content.upsert_document(
        "sheet",
        %{"doc_id" => sheet.doc_id, "content" => sheet_content("second-value")},
        @dataset
      )

    {:ok, _view, refreshed} = live(conn, "/papers/#{@slug}")
    assert refreshed =~ "<table"
    assert refreshed =~ "Metric"
    assert refreshed =~ "second-value"
    refute refreshed =~ "first-value"
  end
end
