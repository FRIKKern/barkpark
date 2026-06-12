defmodule Barkpark.ContentSheetsWritethroughTest do
  @moduledoc """
  Integration lock for the sheet-embed write-through in `Barkpark.Content`:
  mutating a `"sheet"` document through the canonical save paths refreshes the
  `"snapshot"` of every same-scope `{"type":"sheet","ref":…}` block, in the
  same logical operation — and broadcasts for the refreshed docs.

  Also locks the mirror move (M0a embed hydration): saving the EMBEDDING
  document hydrates its sheet blocks' snapshots from the referenced sheets
  immediately, so a doc embedding an existing sheet never waits for the
  sheet's next save to render values.

  Also locks plain sheet CRUD through Content with NO plugin wiring in scope:
  the grid machinery is core, so a sheet document round-trips and its embeds
  refresh even when `Barkpark.Plugins.Sheets` is not loaded (fresh-install
  invariant).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "sheets_wt_test"

  defp sheet_content(value) do
    %{
      "locale" => "nb-NO",
      "tabs" => [
        %{
          "name" => "Tab1",
          "frozen_rows" => 1,
          "cells" => %{
            "A1" => %{"v" => "Name"},
            "A2" => %{"v" => value}
          }
        }
      ]
    }
  end

  defp create_sheet(id, value) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => id, "content" => sheet_content(value)},
        @dataset
      )

    doc
  end

  defp sheet_block(ref, extra \\ %{}) do
    Map.merge(%{"id" => "blk-#{ref}", "type" => "sheet", "ref" => ref, "tab" => 0}, extra)
  end

  defp create_paper(id, blocks) do
    {:ok, doc} =
      Content.create_document(
        "paper",
        %{"doc_id" => id, "content" => %{"blocks" => blocks}},
        @dataset
      )

    doc
  end

  defp reload_blocks(doc) do
    {:ok, doc} = Content.get_document(doc.doc_id, doc.type, @dataset)
    {doc, get_in(doc.content, ["blocks"]) || []}
  end

  # ── CRUD ────────────────────────────────────────────────────────────────────

  describe "sheet document CRUD via Content (no plugin in scope)" do
    test "create lands a draft and round-trips the cell map" do
      doc = create_sheet("crud-1", "Alice")

      assert doc.type == "sheet"
      assert String.starts_with?(doc.doc_id, "drafts.")

      {:ok, fetched} = Content.get_document(doc.doc_id, "sheet", @dataset)
      assert get_in(fetched.content, ["tabs", Access.at(0), "cells", "A2", "v"]) == "Alice"
      assert get_in(fetched.content, ["locale"]) == "nb-NO"
    end

    test "upsert updates cells in place" do
      doc = create_sheet("crud-2", "old")

      {:ok, updated} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => doc.doc_id, "content" => sheet_content("new")},
          @dataset
        )

      assert updated.doc_id == doc.doc_id
      assert get_in(updated.content, ["tabs", Access.at(0), "cells", "A2", "v"]) == "new"
    end
  end

  # ── Write-through ───────────────────────────────────────────────────────────

  describe "write-through — sheet mutation refreshes embedding docs" do
    test "embed referencing the published id refreshes from the draft mutation" do
      sheet = create_sheet("wt-1", "before")
      pub_id = Content.published_id(sheet.doc_id)
      paper = create_paper("wt-paper-1", [sheet_block(pub_id)])

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => sheet_content("after")},
          @dataset
        )

      {refreshed, [block]} = reload_blocks(paper)

      assert block["snapshot"] == %{"head" => ["Name"], "rows" => [["after"]]}
      assert refreshed.rev != paper.rev, "expected the refreshed paper to bump its rev"
    end

    test "embed referencing the draft id refreshes too" do
      sheet = create_sheet("wt-2", "v1")
      paper = create_paper("wt-paper-2", [sheet_block(sheet.doc_id)])

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => sheet_content("v2")},
          @dataset
        )

      {_doc, [block]} = reload_blocks(paper)
      assert block["snapshot"]["rows"] == [["v2"]]
    end

    test "create_document of a sheet also writes through (not just upsert)" do
      # The paper embeds a sheet that does not exist yet; creating the sheet
      # afterwards must backfill the snapshot.
      paper = create_paper("wt-paper-3", [sheet_block("late-sheet")])
      create_sheet("late-sheet", "fresh")

      {_doc, [block]} = reload_blocks(paper)
      assert block["snapshot"]["rows"] == [["fresh"]]
    end

    test "per-block tab index: each embed snapshots its own tab" do
      content = %{
        "tabs" => [
          %{"name" => "T0", "cells" => %{"A1" => %{"v" => "zero"}}},
          %{"name" => "T1", "cells" => %{"A1" => %{"v" => "one"}}}
        ]
      }

      {:ok, sheet} =
        Content.create_document("sheet", %{"doc_id" => "wt-tabs", "content" => content}, @dataset)

      pub_id = Content.published_id(sheet.doc_id)

      paper =
        create_paper("wt-paper-4", [
          Map.put(sheet_block(pub_id), "id", "b0"),
          sheet_block(pub_id) |> Map.put("id", "b1") |> Map.put("tab", 1)
        ])

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => content},
          @dataset
        )

      {_doc, [b0, b1]} = reload_blocks(paper)
      assert b0["snapshot"]["rows"] == [["zero"]]
      assert b1["snapshot"]["rows"] == [["one"]]
    end

    test "the body html cache re-projects with the refreshed grid" do
      sheet = create_sheet("wt-3", "stale-value")
      pub_id = Content.published_id(sheet.doc_id)
      paper = create_paper("wt-paper-5", [sheet_block(pub_id)])

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => sheet_content("projected-value")},
          @dataset
        )

      {refreshed, _blocks} = reload_blocks(paper)
      body_html = get_in(refreshed.content, ["body", "html"]) || ""

      assert body_html =~ "projected-value"
      refute body_html =~ "stale-value"
    end

    test "a paper ingested via upsert_paper refreshes its body_html cache" do
      sheet = create_sheet("wt-cache", "seed")
      pub_id = Content.published_id(sheet.doc_id)

      {:ok, paper} =
        Content.upsert_paper(%{
          slug: "wt-cache-paper",
          dataset: @dataset,
          blocks: [sheet_block(pub_id)]
        })

      for value <- ["cache-old", "cache-new"] do
        {:ok, _} =
          Content.upsert_document(
            "sheet",
            %{"doc_id" => sheet.doc_id, "content" => sheet_content(value)},
            @dataset
          )
      end

      {:ok, refreshed} = Content.get_document(paper.doc_id, "paper", @dataset)
      body_html = get_in(refreshed.content, ["body_html"]) || ""

      assert body_html =~ "cache-new"
      refute body_html =~ "cache-old"
    end

    test "non-sheet blocks and other-ref sheet blocks are untouched" do
      sheet = create_sheet("wt-4", "x")
      pub_id = Content.published_id(sheet.doc_id)

      other = %{"id" => "p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "hi"}]}
      foreign = sheet_block("some-other-sheet") |> Map.put("id", "b-foreign")

      paper = create_paper("wt-paper-6", [other, sheet_block(pub_id), foreign])

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => sheet_content("y")},
          @dataset
        )

      {_doc, [b_other, b_mine, b_foreign]} = reload_blocks(paper)
      assert b_other == other
      assert b_mine["snapshot"]["rows"] == [["y"]]
      refute Map.has_key?(b_foreign, "snapshot")
    end

    test "a doc in another dataset is NOT refreshed (scope boundary)" do
      sheet = create_sheet("wt-5", "a")
      pub_id = Content.published_id(sheet.doc_id)

      {:ok, foreign_paper} =
        Content.create_document(
          "paper",
          %{"doc_id" => "wt-paper-foreign", "content" => %{"blocks" => [sheet_block(pub_id)]}},
          "sheets_wt_other_dataset"
        )

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => sheet_content("b")},
          @dataset
        )

      {:ok, untouched} =
        Content.get_document(foreign_paper.doc_id, "paper", "sheets_wt_other_dataset")

      [block] = get_in(untouched.content, ["blocks"])
      refute Map.has_key?(block, "snapshot")
    end

    test "a sheet never refreshes itself (self-embed guard) and saves terminate" do
      content = %{
        "tabs" => [%{"cells" => %{"A1" => %{"v" => "self"}}}],
        "blocks" => [sheet_block("wt-self")]
      }

      {:ok, doc} =
        Content.create_document("sheet", %{"doc_id" => "wt-self", "content" => content}, @dataset)

      {:ok, fetched} = Content.get_document(doc.doc_id, "sheet", @dataset)
      [block] = get_in(fetched.content, ["blocks"])
      refute Map.has_key?(block, "snapshot")
    end

    test "mutating a sheet nothing embeds is a clean no-op" do
      assert %{} = create_sheet("wt-lonely", "solo")
    end
  end

  # ── Embed hydration (M0a) ───────────────────────────────────────────────────

  describe "embed hydration — the embedding doc's own save" do
    test "a paper created AFTER the sheet hydrates its snapshot immediately" do
      sheet = create_sheet("hy-1", "ready")
      pub_id = Content.published_id(sheet.doc_id)

      paper = create_paper("hy-paper-1", [sheet_block(pub_id)])

      # No sheet mutation since the embed — the paper's own save hydrated.
      [block] = get_in(paper.content, ["blocks"])
      assert block["snapshot"] == %{"head" => ["Name"], "rows" => [["ready"]]}
    end

    test "upsert_paper hydrates at ingest and renders values into body_html" do
      sheet = create_sheet("hy-2", "ingest-value")
      pub_id = Content.published_id(sheet.doc_id)

      {:ok, paper} =
        Content.upsert_paper(%{
          slug: "hy-paper-2",
          dataset: @dataset,
          blocks: [sheet_block(pub_id)]
        })

      [block] = get_in(paper.content, ["blocks"])
      assert block["snapshot"]["rows"] == [["ingest-value"]]
      assert get_in(paper.content, ["body_html"]) =~ "ingest-value"
    end

    test "a ref to a missing sheet stays an untouched empty-grid placeholder" do
      paper = create_paper("hy-paper-3", [sheet_block("hy-never-created")])

      [block] = get_in(paper.content, ["blocks"])
      refute Map.has_key?(block, "snapshot")
    end

    test "a mixed multi-ref doc hydrates each block from its own sheet" do
      a = create_sheet("hy-a", "alpha")
      b = create_sheet("hy-b", "beta")

      other = %{"id" => "p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "hi"}]}

      paper =
        create_paper("hy-paper-4", [
          other,
          sheet_block(Content.published_id(a.doc_id)),
          # Draft-form ref hydrates too — both id forms resolve.
          sheet_block(b.doc_id),
          sheet_block("hy-missing") |> Map.put("id", "b-miss")
        ])

      [b_other, b_a, b_b, b_miss] = get_in(paper.content, ["blocks"])
      assert b_other == other
      assert b_a["snapshot"]["rows"] == [["alpha"]]
      assert b_b["snapshot"]["rows"] == [["beta"]]
      refute Map.has_key?(b_miss, "snapshot")
    end

    test "upsert_document with blocks hydrates and projection sees the grid" do
      sheet = create_sheet("hy-3", "upserted")
      pub_id = Content.published_id(sheet.doc_id)

      {:ok, doc} =
        Content.upsert_document(
          "paper",
          %{"doc_id" => "hy-paper-5", "content" => %{"blocks" => [sheet_block(pub_id)]}},
          @dataset
        )

      [block] = get_in(doc.content, ["blocks"])
      assert block["snapshot"]["rows"] == [["upserted"]]
      assert (get_in(doc.content, ["body", "html"]) || "") =~ "upserted"
    end

    test "a carried-along stale snapshot is re-hydrated on the embedding doc's save" do
      sheet = create_sheet("hy-4", "current")
      pub_id = Content.published_id(sheet.doc_id)
      stale = sheet_block(pub_id) |> Map.put("snapshot", %{"rows" => [["stale"]]})

      paper = create_paper("hy-paper-6", [stale])

      [block] = get_in(paper.content, ["blocks"])
      assert block["snapshot"]["rows"] == [["current"]]
    end
  end

  # ── Formula recompute (M3) ──────────────────────────────────────────────────

  defp formula_content(a1) do
    %{
      "tabs" => [
        %{
          "name" => "Calc",
          "cells" => %{
            "A1" => %{"v" => a1},
            "A2" => %{"v" => 3},
            "A3" => %{"f" => "A1*A2"}
          }
        }
      ]
    }
  end

  describe "formula recompute on the save path" do
    test "create computes formula cells before the row persists" do
      {:ok, doc} =
        Content.create_document(
          "sheet",
          %{"doc_id" => "m3-create", "content" => formula_content(2)},
          @dataset
        )

      {:ok, fetched} = Content.get_document(doc.doc_id, "sheet", @dataset)
      cell = get_in(fetched.content, ["tabs", Access.at(0), "cells", "A3"])
      assert cell["v"] == 6
      assert cell["t"] == "n"
    end

    test "upsert recomputes: changing an input updates dependent formulas" do
      {:ok, doc} =
        Content.create_document(
          "sheet",
          %{"doc_id" => "m3-upsert", "content" => formula_content(2)},
          @dataset
        )

      {:ok, updated} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => doc.doc_id, "content" => formula_content(5)},
          @dataset
        )

      assert get_in(updated.content, ["tabs", Access.at(0), "cells", "A3", "v"]) == 15
    end

    test "write-through snapshots carry COMPUTED values into embedding docs" do
      {:ok, sheet} =
        Content.create_document(
          "sheet",
          %{"doc_id" => "m3-wt", "content" => formula_content(2)},
          @dataset
        )

      pub_id = Content.published_id(sheet.doc_id)
      paper = create_paper("m3-wt-paper", [sheet_block(pub_id)])

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => formula_content(7)},
          @dataset
        )

      {_doc, [block]} = reload_blocks(paper)
      assert block["snapshot"]["rows"] == [["7"], ["3"], ["21"]]
    end

    test "a cycle lands as #CYCLE! in the doc and its snapshots" do
      content = %{
        "tabs" => [
          %{"cells" => %{"A1" => %{"f" => "B1+1"}, "B1" => %{"f" => "A1+1"}}}
        ]
      }

      {:ok, sheet} =
        Content.create_document("sheet", %{"doc_id" => "m3-cycle", "content" => content}, @dataset)

      pub_id = Content.published_id(sheet.doc_id)
      paper = create_paper("m3-cycle-paper", [sheet_block(pub_id)])

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => content},
          @dataset
        )

      {:ok, fetched} = Content.get_document(sheet.doc_id, "sheet", @dataset)
      assert get_in(fetched.content, ["tabs", Access.at(0), "cells", "A1", "v"]) == "#CYCLE!"

      {_doc, [block]} = reload_blocks(paper)
      assert block["snapshot"]["rows"] == [["#CYCLE!", "#CYCLE!"]]
    end

    test "unknown function survives the save stale, keeping its cached value" do
      content = %{
        "tabs" => [
          %{"cells" => %{"A1" => %{"f" => "NPV(0.1,5)", "v" => 42, "t" => "n"}}}
        ]
      }

      {:ok, doc} =
        Content.create_document("sheet", %{"doc_id" => "m3-stale", "content" => content}, @dataset)

      {:ok, fetched} = Content.get_document(doc.doc_id, "sheet", @dataset)
      cell = get_in(fetched.content, ["tabs", Access.at(0), "cells", "A1"])
      assert cell["v"] == 42
      assert cell["stale"] == true
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────────────

  describe "write-through — broadcasts" do
    test "the refreshed paper broadcasts on the dataset topic" do
      sheet = create_sheet("wt-ps", "one")
      pub_id = Content.published_id(sheet.doc_id)
      paper = create_paper("wt-paper-ps", [sheet_block(pub_id)])

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => sheet_content("two")},
          @dataset
        )

      # Two broadcasts land, in save order: the sheet itself, then the
      # refreshed paper — write-through rides the same logical operation.
      assert_receive {:document_changed, %{type: "sheet"}}, 1_000
      assert_receive {:document_changed, %{type: "paper", doc_id: doc_id}}, 1_000
      assert doc_id == paper.doc_id
    end
  end
end
