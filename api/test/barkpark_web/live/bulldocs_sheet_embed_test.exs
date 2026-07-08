defmodule BarkparkWeb.BulldocsSheetEmbedTest do
  @moduledoc """
  End-to-end View-mode lock for the `"sheet"` embed block: a paper ingested
  with a sheet block hydrates its snapshot at ingest (M0a) and renders the
  grid values in the Bulldocs reader on the FIRST read. Because the paper is
  PUBLISHED, a mere DRAFT edit of the referenced sheet must NOT reach the
  reader (that would leak draft cell values to anonymous /papers visitors —
  the draft-content boundary); the reader's snapshot moves only when the sheet
  itself is PUBLISHED, at which point the write-through refreshes it. No plugin
  in the loop — the block composes straight from its cached snapshot
  (fresh-install invariant).
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

    # Ingest a paper embedding the sheet. The sheet already exists, so the
    # ingest hydrates the block's snapshot immediately (M0a) — the reader's
    # first render shows the grid values, no post-embed sheet save needed.
    {:ok, _paper} =
      Content.upsert_paper(%{
        slug: @slug,
        blocks: [%{"id" => "s1", "type" => "sheet", "ref" => pub_id, "tab" => 0}]
      })

    {:ok, _view, html} = live(conn, "/papers/#{@slug}")
    assert html =~ "<table"
    assert html =~ "Metric"
    assert html =~ "first-value"

    # DRAFT edit of the sheet: the published paper's snapshot must stay put —
    # a draft autosave cannot publish "second-value" to anonymous readers.
    {:ok, _} =
      Content.upsert_document(
        "sheet",
        %{"doc_id" => sheet.doc_id, "content" => sheet_content("second-value")},
        @dataset
      )

    {:ok, _view, mid} = live(conn, "/papers/#{@slug}")
    assert mid =~ "first-value", "the published reader must stay frozen on the published value"
    refute mid =~ "second-value", "a draft sheet edit must not leak into the published reader"

    # PUBLISH the sheet: NOW the write-through refreshes the published paper's
    # snapshot (and its body_html cache) in the same logical operation.
    {:ok, _} = Content.publish_document(sheet.doc_id, "sheet", @dataset)

    {:ok, _view, refreshed} = live(conn, "/papers/#{@slug}")
    assert refreshed =~ "<table"
    assert refreshed =~ "Metric"
    assert refreshed =~ "second-value"
    refute refreshed =~ "first-value"
  end
end
