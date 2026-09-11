defmodule Barkpark.Content.Papers.CanvasRunContextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.CanvasRunContext

  test "spliced document results retain the whole-document lock and identity fences" do
    locked = %{"id" => "locked", "type" => "heading", "locked" => true}
    before = [paragraph("a"), locked]
    op = %{"op" => "canvas-run"}

    assert {:error, {:locked_block, "locked", "canvas-run"}} =
             Barkpark.PortableDoc.Patch.validate_result(
               before,
               [paragraph("new") | before],
               op,
               []
             )

    assert {:error, _duplicate} =
             Barkpark.PortableDoc.Patch.validate_result(
               before,
               before ++ [paragraph("a")],
               op,
               []
             )

    assert {:ok, ^before} = Barkpark.PortableDoc.Patch.validate_result(before, before, op, [])

    constraints = [
      %{
        kind: "paragraph",
        presence: :required,
        count: {:max, 1},
        position: [:free],
        locked: false
      }
    ]

    assert {:error, {:constraint, _message, "canvas-run"}} =
             Barkpark.PortableDoc.Patch.validate_result(
               [paragraph("a")],
               [paragraph("a"), paragraph("b")],
               op,
               constraints: constraints
             )
  end

  test "document run replacements stay between their untouched neighbors" do
    before = %{"id" => "quote", "type" => "blockquote", "qa" => %{"keep" => true}}
    blocks = [paragraph("title"), before, paragraph("trigger"), paragraph("tail")]
    context = %{container_kind: "document", container_run_ids: ["trigger", "tail"]}
    callout = %{"id" => "new", "type" => "callout", "content" => []}

    assert {:ok, ^context} = CanvasRunContext.normalize(context)

    assert {:ok, updated, :folded} =
             CanvasRunContext.map_run(blocks, context, fn [_trigger, tail] ->
               {:ok, [callout, tail], :folded}
             end)

    assert updated == [paragraph("title"), before, callout, paragraph("tail")]

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run(
               blocks,
               %{context | container_run_ids: ["trigger", "title"]},
               fn _ ->
                 flunk("stale or non-contiguous document runs must not reach the fold")
               end
             )

    assert {:error, :canvas_run_id_collision} =
             CanvasRunContext.map_run(blocks, context, fn run ->
               {:ok, [paragraph("title") | run], :folded}
             end)

    for extra <- [
          %{container_id: "quote"},
          %{container_row_id: "row"},
          %{container_column_index: 0}
        ] do
      assert {:error, :invalid_canvas_run_context} =
               CanvasRunContext.normalize(Map.merge(context, extra))
    end
  end

  test "normalizes the stable boundary context and rejects ambiguous shapes" do
    assert {:ok, %{container_id: "details", container_run_ids: ["a", "b"]}} =
             CanvasRunContext.normalize(%{
               "container_id" => "details",
               "container_run_ids" => ["a", "b"]
             })

    assert {:error, :invalid_canvas_run_context} =
             CanvasRunContext.normalize(%{container_id: "details", container_run_ids: []})

    assert {:error, :invalid_canvas_run_context} =
             CanvasRunContext.normalize(%{
               container_id: "details",
               container_run_ids: ["a", "a"]
             })
  end

  test "maps exactly one contiguous run through the renderer-visible children alias" do
    blocks = [
      %{
        "id" => "details",
        "type" => "expandable",
        "summary" => "Keep metadata",
        "children" => [paragraph("before"), paragraph("a"), paragraph("b"), paragraph("after")],
        "blocks" => [paragraph("hidden")]
      },
      paragraph("outside")
    ]

    context = %{container_id: "details", container_run_ids: ["a", "b"]}

    assert {:ok, [updated, outside], :folded} =
             CanvasRunContext.map_run(blocks, context, fn run ->
               assert Enum.map(run, & &1["id"]) == ["a", "b"]
               {:ok, run ++ [paragraph("new")], :folded}
             end)

    assert updated["summary"] == "Keep metadata"
    assert Enum.map(updated["children"], & &1["id"]) == ["before", "a", "b", "new", "after"]
    assert Enum.map(updated["blocks"], & &1["id"]) == ["hidden"]
    assert outside == paragraph("outside")
  end

  test "resolves recursively and refuses non-contiguous, duplicate-container, and escaping ids" do
    nested = %{
      "id" => "section",
      "type" => "section",
      "blocks" => [
        %{
          "id" => "details",
          "type" => "expandable",
          "blocks" => [paragraph("a"), paragraph("boundary"), paragraph("b")]
        }
      ]
    }

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run(
               [nested],
               %{container_id: "details", container_run_ids: ["a", "b"]},
               fn _ -> flunk("a non-contiguous baseline must not reach the fold") end
             )

    duplicate = [nested, Map.put(hd(nested["blocks"]), "blocks", [paragraph("a")])]

    assert {:error, :canvas_run_container_ambiguous} =
             CanvasRunContext.map_run(
               duplicate,
               %{container_id: "details", container_run_ids: ["a"]},
               fn _ -> flunk("an ambiguous container must not reach the fold") end
             )

    contiguous = put_in(nested, ["blocks", Access.at(0), "blocks"], [paragraph("a")])

    assert {:error, :canvas_run_id_collision} =
             CanvasRunContext.map_run(
               [contiguous, paragraph("outside")],
               %{container_id: "details", container_run_ids: ["a"]},
               fn run -> {:ok, run ++ [paragraph("outside")], :folded} end
             )
  end

  test "does not punish an unrelated legacy duplicate when its count does not increase" do
    blocks = [
      %{
        "id" => "details",
        "type" => "expandable",
        "children" => [paragraph("a")]
      },
      paragraph("legacy"),
      paragraph("legacy")
    ]

    assert {:ok, updated, :folded} =
             CanvasRunContext.map_run(
               blocks,
               %{container_id: "details", container_run_ids: ["a"]},
               fn [block] -> {:ok, [Map.put(block, "text", "changed")], :folded} end
             )

    assert get_in(hd(updated), ["children", Access.at(0), "text"]) == "changed"
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "text" => id}
end
