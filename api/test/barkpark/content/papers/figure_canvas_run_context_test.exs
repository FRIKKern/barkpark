defmodule Barkpark.Content.Papers.FigureCanvasRunContextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.CanvasRunContext

  test "normalizes only the strict rowless one-child figure context" do
    assert {:ok,
            %{
              container_kind: "figure",
              container_id: "figure-a",
              container_run_ids: ["child-a"]
            }} =
             CanvasRunContext.normalize(%{
               "container_kind" => "figure",
               "container_id" => "figure-a",
               "container_run_ids" => ["child-a"]
             })

    invalid = [
      %{container_kind: "figure", container_id: "figure-a", container_run_ids: []},
      %{container_kind: "figure", container_id: "figure-a", container_run_ids: ["a", "b"]},
      %{
        container_kind: "figure",
        container_id: "figure-a",
        container_row_id: "forbidden",
        container_run_ids: ["child-a"]
      },
      %{container_kind: "figure", container_run_ids: ["child-a"]},
      %{container_kind: "figure", container_id: "figure-a"}
    ]

    for raw <- invalid do
      assert {:error, :invalid_canvas_run_context} = CanvasRunContext.normalize(raw)

      assert {:error, :invalid_canvas_run_context} =
               CanvasRunContext.map_run([figure()], raw, &unchanged/1)
    end

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run(
               [figure()],
               %{container_id: "figure-a", container_run_ids: ["child-a"]},
               &unchanged/1
             )
  end

  test "maps exactly one singular child and preserves every surrounding value" do
    block =
      figure(%{
        "id" => "child-a",
        "type" => "paragraph",
        "text" => "Before",
        "child-meta" => %{"keep" => true}
      })
      |> Map.merge(%{
        "caption" => "Keep caption",
        "figure-meta" => [1, 2],
        "children" => [paragraph("opaque")],
        "blocks" => [paragraph("shadow")]
      })

    assert {:ok, [updated, outside], :changed} =
             CanvasRunContext.map_run([block, paragraph("outside")], context(), fn [child] ->
               assert child["id"] == "child-a"
               {:ok, [Map.put(child, "text", "After")], :changed}
             end)

    assert updated["child"]["text"] == "After"
    assert updated["child"]["child-meta"] == %{"keep" => true}
    assert updated["caption"] == "Keep caption"
    assert updated["figure-meta"] == [1, 2]
    assert updated["children"] == [paragraph("opaque")]
    assert updated["blocks"] == [paragraph("shadow")]
    assert outside == paragraph("outside")
  end

  test "rejects every callback result except exactly one map" do
    for next_run <- [[], [paragraph("one"), paragraph("two")], "scalar", ["scalar"]] do
      assert {:error, :canvas_run_figure_cardinality} =
               CanvasRunContext.map_run([figure()], context(), fn [_child] ->
                 {:ok, next_run, :changed}
               end)
    end
  end

  test "resolves one typed parent and exact confirmed child id" do
    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([figure()], context("wrong"), &unchanged/1)

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run(
               [%{"id" => "figure-a", "type" => "card", "child" => paragraph("child-a")}],
               context(),
               &unchanged/1
             )

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run(
               [figure()],
               context("figure-a", "wrong-child"),
               &unchanged/1
             )

    assert {:error, :canvas_run_container_ambiguous} =
             CanvasRunContext.map_run([figure(), figure()], context(), &unchanged/1)

    for malformed <- [nil, false, "scalar", [], [paragraph("child-a")]] do
      assert {:error, :canvas_run_figure_cardinality} =
               CanvasRunContext.map_run(
                 [%{"id" => "figure-a", "type" => "figure", "child" => malformed}],
                 context(),
                 &unchanged/1
               )
    end
  end

  test "finds a nested figure only through a valid singular figure child" do
    target = figure()

    outer =
      %{
        "id" => "outer",
        "type" => "figure",
        "outer-meta" => %{"keep" => true},
        "child" => %{
          "id" => "section",
          "type" => "section",
          "blocks" => [target]
        },
        "children" => [target],
        "blocks" => [target]
      }

    assert {:ok, [updated], :changed} =
             CanvasRunContext.map_run([outer], context(), fn [child] ->
               {:ok, [Map.put(child, "nested", true)], :changed}
             end)

    assert get_in(updated, ["child", "blocks", Access.at(0), "child", "nested"]) == true
    assert updated["outer-meta"] == %{"keep" => true}
    assert updated["children"] == [target]
    assert updated["blocks"] == [target]

    malformed_outer = Map.put(outer, "child", [outer["child"]])

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([malformed_outer], context(), &unchanged/1)
  end

  test "collision census includes the figure identity and valid child descendants only" do
    block =
      figure(%{
        "id" => "child-a",
        "type" => "section",
        "blocks" => [paragraph("nested")]
      })
      |> Map.put("metadata", %{"id" => "opaque"})
      |> Map.put("children", [paragraph("opaque")])

    for colliding_id <- ["figure-a", "nested", "outside"] do
      assert {:error, :canvas_run_id_collision} =
               CanvasRunContext.map_run([block, paragraph("outside")], context(), fn [child] ->
                 replacement =
                   Map.put(
                     child,
                     "blocks",
                     Map.get(child, "blocks", []) ++ [paragraph(colliding_id)]
                   )

                 {:ok, [replacement], :changed}
               end)
    end

    assert {:ok, _updated, :changed} =
             CanvasRunContext.map_run([block], context(), fn [child] ->
               {:ok, [Map.put(child, "id", "opaque")], :changed}
             end)

    legacy = [figure(), paragraph("legacy"), paragraph("legacy")]

    assert {:ok, _updated, :changed} =
             CanvasRunContext.map_run(legacy, context(), fn [child] ->
               {:ok, [Map.put(child, "text", "changed")], :changed}
             end)
  end

  defp context(parent_id \\ "figure-a", child_id \\ "child-a") do
    %{
      container_kind: "figure",
      container_id: parent_id,
      container_run_ids: [child_id]
    }
  end

  defp figure(child \\ paragraph("child-a")) do
    %{
      "id" => "figure-a",
      "type" => "figure",
      "child" => child
    }
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "text" => id}
  defp unchanged(run), do: {:ok, run, :unchanged}
end
