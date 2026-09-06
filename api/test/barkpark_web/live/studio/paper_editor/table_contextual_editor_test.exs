defmodule BarkparkWeb.Studio.PaperEditor.TableContextualEditorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "Table receipts carry a current wire projection without raw metadata or stale receipt revision" do
    receipt = %{saved: true, request_id: "retry", replayed: true, rev: 1}
    op = %{"op" => "patch-table-structure", "id" => "table"}
    confirmed = Paper.table_confirmation(receipt, op, [table()], 3)

    assert confirmed.rev == 1
    assert confirmed.table_projection_rev == 3
    assert confirmed.table_projection.rows == [[[%{"type" => "text", "value" => "Cell"}]]]

    assert Map.keys(confirmed.table_projection) |> Enum.sort() == [
             :head,
             :id,
             :rows,
             :shape,
             :type
           ]

    assert Paper.table_confirmation(receipt, op, nil, nil).table_projection == nil
    assert Paper.table_confirmation(receipt, %{"op" => "patch-block"}, [table()], 3) == receipt
  end

  test "new Table runs are contextual boundaries, with one projected whole-Table editor" do
    table = table()
    assert PaperCanvas.partition_runs([table]) == [{:block, table}]

    for canvas? <- [true, false] do
      tree = render_editor([table], canvas?) |> LazyHTML.from_fragment()
      editors = LazyHTML.query(tree, "bp-paper-editor[data-editor-mode='table']")
      assert Enum.count(editors) == 1
      [projection] = LazyHTML.attribute(editors, "data-block") |> Enum.map(&Jason.decode!/1)
      assert projection["id"] == "table"
      assert projection["rows"] == [[[%{"type" => "text", "value" => "Cell"}]]]
      assert projection["shape"]["v"] == 1
      refute Map.has_key?(projection, "private-metadata")
      assert Enum.empty?(LazyHTML.query(tree, ".bp-table"))
    end
  end

  test "raw authored eligibility survives nested grid and Columns rendering" do
    for parent <- [
          %{
            "id" => "section",
            "type" => "section",
            "layout" => %{"kind" => "grid", "tracks" => 2},
            "blocks" => [table()]
          },
          %{"id" => "columns", "type" => "columns", "columns" => [[table()]]}
        ] do
      tree = render_editor([parent], true) |> LazyHTML.from_fragment()
      assert Enum.count(LazyHTML.query(tree, "bp-paper-editor[data-editor-mode='table']")) == 1
    end
  end

  test "idless and legacy-risk tables keep canonical preview without editable controls" do
    for blocks <- [
          [Map.delete(table(), "id")],
          [table(), %{"id" => "legacy", "type" => "table", "rows" => [["Legacy cell"]]}]
        ] do
      tree = render_editor(blocks, true) |> LazyHTML.from_fragment()
      assert Enum.empty?(LazyHTML.query(tree, "bp-paper-editor[data-editor-mode='table']"))

      assert Enum.count(LazyHTML.query(tree, "[data-test-id='paper-table-readonly']")) ==
               length(blocks)

      assert Enum.count(LazyHTML.query(tree, ".bp-table")) == length(blocks)

      assert Enum.count(
               LazyHTML.query(
                 tree,
                 "[data-test-id='paper-table-contextual-editor'][phx-update='ignore']"
               )
             ) == length(blocks)
    end
  end

  test "Beta pre-projection refusal cannot be replaced by apparently valid projected IDs" do
    projected = Barkpark.Content.ensure_block_ids([Map.delete(table(), "id")])

    tree =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "test",
        blocks: projected,
        doc_type: "post",
        table_editor_target_ids: MapSet.new()
      )
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(tree, "bp-paper-editor[data-editor-mode='table']"))
    assert Enum.count(LazyHTML.query(tree, "[data-test-id='paper-table-readonly']")) == 1
  end

  defp render_editor(blocks, canvas?) do
    render_component(&PaperEditor.paper_block_editor/1,
      slug: "table-test",
      blocks: blocks,
      canvas_eligible: canvas?,
      paper_rev: 1
    )
  end

  defp table do
    %{
      "id" => "table",
      "type" => "table",
      "rows" => [[[%{"type" => "text", "value" => "Cell"}]]],
      "private-metadata" => true
    }
  end
end
