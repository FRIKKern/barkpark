defmodule Barkpark.Content.Papers.TerminalCanvasRunContextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.CanvasRunContext
  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "accepts rowless Terminal context and rejects coordinates or empty runs" do
    context = context()
    assert {:ok, ^context} = CanvasRunContext.normalize(context)

    for invalid <- [
          Map.put(context, :container_row_id, "row"),
          Map.put(context, :container_column_index, 0),
          Map.put(context, :container_run_ids, []),
          Map.put(context, :container_run_ids, ["a", "a"]),
          Map.put(context, :container_id, ""),
          Map.put(context, "container_kind", "section")
        ] do
      assert {:error, :invalid_canvas_run_context} = CanvasRunContext.normalize(invalid)
    end
  end

  test "maps only the exact canonical run and preserves parent and sibling metadata" do
    terminal = terminal([paragraph("before"), paragraph("a"), paragraph("b"), paragraph("after")])
    original = [terminal, paragraph("outside")]

    assert {:ok, [updated, outside], :changed} =
             CanvasRunContext.map_run(original, context(), fn [a, b] ->
               {:ok, [Map.put(a, "content", [%{"type" => "text", "value" => "Changed"}]), b],
                :changed}
             end)

    assert Map.delete(updated, "children") == Map.delete(terminal, "children")
    assert Enum.map(updated["children"], & &1["id"]) == ["before", "a", "b", "after"]
    assert Enum.at(updated["children"], 1)["qa"] == "a"
    assert Enum.at(updated["children"], 2) == paragraph("b")
    assert outside == paragraph("outside")

    assert {:ok, ^original, :same} =
             CanvasRunContext.map_run(original, context(), &{:ok, &1, :same})
  end

  test "legacy, dual and malformed bodies cannot be selected or recursively targeted" do
    nested = %{"type" => "section", "id" => "inner", "blocks" => [paragraph("a"), paragraph("b")]}

    for body <- [
          %{"blocks" => [nested]},
          %{"children" => [nested], "blocks" => []},
          %{"children" => [], "blocks" => [nested]},
          %{"children" => nil},
          %{"children" => false},
          %{"children" => "opaque", "blocks" => [nested]}
        ] do
      raw = Map.merge(%{"type" => "terminal", "id" => "term"}, body)

      assert {:error, :canvas_run_container_children_invalid} =
               CanvasRunContext.map_run([raw], context(), fn _ ->
                 flunk("opaque Terminal was editable")
               end)

      assert {:error, :canvas_run_container_not_found} =
               CanvasRunContext.map_run(
                 [raw],
                 %{context() | container_kind: "section", container_id: "inner"},
                 fn _ ->
                   flunk("hidden descendant was editable")
                 end
               )

      assert Blocks.find_paper_block([raw], "a") == nil
      assert Blocks.container_children(raw) == []
    end
  end

  test "finds Terminal inside Columns and Section inside canonical Terminal" do
    terminal = terminal([paragraph("a"), paragraph("b")])
    tree = [%{"type" => "columns", "id" => "cols", "columns" => [[terminal]]}]
    assert {:ok, ^tree, :same} = CanvasRunContext.map_run(tree, context(), &{:ok, &1, :same})
    assert Blocks.find_paper_block(tree, "a") == paragraph("a")
    assert Blocks.container_children(terminal) == terminal["children"]

    inner = %{"type" => "section", "id" => "inner", "blocks" => [paragraph("a"), paragraph("b")]}
    tree = [terminal([inner])]
    inner_context = %{context() | container_kind: "section", container_id: "inner"}
    assert {:ok, ^tree, :same} = CanvasRunContext.map_run(tree, inner_context, &{:ok, &1, :same})
  end

  test "rejects wrong, noncontiguous and ambiguous Terminal runs before callback" do
    raw = terminal([paragraph("a"), paragraph("gap"), paragraph("b")])

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run([raw], context(), fn _ -> flunk("wrong run") end)

    raw = terminal([paragraph("a"), paragraph("b")])

    assert {:error, :canvas_run_container_ambiguous} =
             CanvasRunContext.map_run([raw, raw], context(), fn _ -> flunk("ambiguous") end)

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([raw], %{context() | container_id: "other"}, fn _ ->
               flunk("wrong parent")
             end)
  end

  test "hidden aliases reserve IDs against new run collisions" do
    for alias_key <- ["children", "blocks"] do
      hidden = %{"type" => "terminal", "id" => "legacy", "children" => [], "blocks" => []}
      hidden = Map.put(hidden, alias_key, [paragraph("reserved")])
      tree = [terminal([paragraph("a"), paragraph("b")]), hidden]

      assert {:error, :canvas_run_id_collision} =
               CanvasRunContext.map_run(tree, context(), fn run ->
                 {:ok, run ++ [paragraph("reserved")], :bad}
               end)
    end
  end

  defp context,
    do: %{container_kind: "terminal", container_id: "term", container_run_ids: ["a", "b"]}

  defp terminal(children),
    do: %{
      "type" => "terminal",
      "id" => "term",
      "children" => children,
      "live" => "live",
      "footer" => nil,
      "qa" => %{"preserve" => true}
    }

  defp paragraph(id),
    do: %{
      "type" => "paragraph",
      "id" => id,
      "content" => [%{"type" => "text", "value" => id}],
      "qa" => id
    }
end
