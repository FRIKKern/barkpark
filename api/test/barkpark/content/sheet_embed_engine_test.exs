defmodule Barkpark.Content.SheetEmbedEngineTest do
  @moduledoc """
  task-0b7e83682d7a7140: `Barkpark.Content.Sheets` reaches the spreadsheet
  engine (formula recompute and embed snapshots) only through the
  content-owned `SheetEmbedEngine` seam, which the Sheets plugin fills via
  `sheet_embed_engine/0`.

  The "Sheets disabled" half takes the Sheets plugin out of the load order
  (`PluginEnv.with_plugins/2`), the same way an operator leaves it out of
  `BARKPARK_PLUGINS`. A sheet save then stores its content without a recompute,
  and every embed keeps its cached snapshot. Nothing raises. The control in the
  same describe runs the same save with Sheets in the load order and must
  refresh, so "unchanged" is measured against a path that does change.

  The refresh behaviour with the engine present is pinned by
  `content_sheets_writethrough_test.exs`; the kill-switch boot half
  (`get/0 == nil`) is in `plugin_free_boot_test.exs`.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.SheetEmbedEngine

  @dataset "sheet_embed_engine_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp sheet_content(value, formula \\ nil) do
    b1 = if formula, do: %{"B1" => %{"f" => formula}}, else: %{}

    %{
      "tabs" => [
        %{
          "name" => "Tab1",
          "frozen_rows" => 1,
          "cells" => Map.merge(%{"A1" => %{"v" => "Name"}, "A2" => %{"v" => value}}, b1)
        }
      ]
    }
  end

  defp save_sheet(id, content) do
    {:ok, doc} =
      Content.upsert_document("sheet", %{"doc_id" => id, "content" => content}, @dataset)

    doc
  end

  defp create_paper(id, ref) do
    block = %{"id" => "blk-#{id}", "type" => "sheet", "ref" => ref, "tab" => 0}

    {:ok, doc} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => id,
          "content" => Barkpark.LabelFixtures.with_labels(%{"blocks" => [block]})
        },
        @dataset
      )

    doc
  end

  defp snapshot(paper) do
    {:ok, doc} = Content.get_document(paper.doc_id, "paper", @dataset)
    {doc.rev, get_in(doc.content, ["blocks", Access.at(0), "snapshot"])}
  end

  test "the Sheets plugin declares its engine and the Registry publishes it" do
    assert Barkpark.Plugins.Sheets.sheet_embed_engine() == Barkpark.Plugins.Sheets.EmbedEngine
    assert SheetEmbedEngine.get() == Barkpark.Plugins.Sheets.EmbedEngine

    # Control for the "not recomputed" assertion below: with the engine
    # present the same formula content does change.
    refute SheetEmbedEngine.recompute(sheet_content("y", "=1+1")) == sheet_content("y", "=1+1")
  end

  test "a plugin that declares nothing publishes no engine" do
    assert Barkpark.Plugins.Tasks.sheet_embed_engine() == nil
  end

  describe "embed refresh with the Sheets plugin out of the load order" do
    test "a sheet save leaves embeds on their cached snapshot and raises nothing", ctx do
      sheet = save_sheet("see-sheet-1", sheet_content("before"))
      paper = create_paper("see-paper-1", Content.published_id(sheet.doc_id))
      {rev_before, snap_before} = snapshot(paper)
      assert snap_before["rows"] == [["before"]]

      :ok = Barkpark.PluginEnv.with_plugins([Barkpark.Plugins.Tasks], ctx)
      assert SheetEmbedEngine.get() == nil

      saved = save_sheet(sheet.doc_id, sheet_content("after"))
      assert get_in(saved.content, ["tabs", Access.at(0), "cells", "A2", "v"]) == "after"

      assert snapshot(paper) == {rev_before, snap_before}
      assert Content.Sheets.refresh_sheet_embeds(saved) == %{rewritten: 0, noop: 0}
    end

    test "control: with Sheets in the load order the same save refreshes the embed", ctx do
      sheet = save_sheet("see-sheet-2", sheet_content("before"))
      paper = create_paper("see-paper-2", Content.published_id(sheet.doc_id))

      :ok =
        Barkpark.PluginEnv.with_plugins([Barkpark.Plugins.Tasks, Barkpark.Plugins.Sheets], ctx)

      assert SheetEmbedEngine.get() == Barkpark.Plugins.Sheets.EmbedEngine

      save_sheet(sheet.doc_id, sheet_content("after"))
      {_rev, snap} = snapshot(paper)
      assert snap["rows"] == [["after"]]
    end

    test "a new embed stores its block as sent, and a formula is not recomputed", ctx do
      sheet = save_sheet("see-sheet-3", sheet_content("x"))
      :ok = Barkpark.PluginEnv.with_plugins([Barkpark.Plugins.Tasks], ctx)

      paper = create_paper("see-paper-3", Content.published_id(sheet.doc_id))
      assert {_rev, nil} = snapshot(paper)

      assert SheetEmbedEngine.recompute(sheet_content("y", "=1+1")) ==
               sheet_content("y", "=1+1")
    end
  end
end
