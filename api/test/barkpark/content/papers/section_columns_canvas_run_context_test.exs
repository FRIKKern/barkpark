defmodule Barkpark.Content.Papers.SectionColumnsCanvasRunContextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.CanvasRunContext

  test "normalizes strict section and columns contexts without changing legacy shapes" do
    legacy = %{container_id: "details", container_run_ids: ["a"]}
    assert {:ok, ^legacy} = CanvasRunContext.normalize(legacy)

    assert {:ok,
            %{
              container_kind: "section",
              container_id: "section",
              container_run_ids: ["a", "b"]
            }} =
             CanvasRunContext.normalize(%{
               "container_kind" => "section",
               "container_id" => "section",
               "container_run_ids" => ["a", "b"]
             })

    assert {:ok,
            %{
              container_kind: "columns",
              container_id: "grid",
              container_column_index: 1,
              container_run_ids: ["a"]
            }} =
             CanvasRunContext.normalize(%{
               container_kind: "columns",
               container_id: "grid",
               container_column_index: 1,
               container_run_ids: ["a"]
             })

    invalid = [
      %{
        container_kind: "section",
        container_id: "section",
        container_row_id: "row",
        container_run_ids: ["a"]
      },
      %{
        container_kind: "section",
        container_id: "section",
        container_column_index: 0,
        container_run_ids: ["a"]
      },
      %{container_kind: "columns", container_id: "grid", container_run_ids: ["a"]},
      %{
        container_kind: "columns",
        container_id: "grid",
        container_column_index: "0",
        container_run_ids: ["a"]
      },
      %{
        container_kind: "columns",
        container_id: "grid",
        container_column_index: 0.0,
        container_run_ids: ["a"]
      },
      %{
        container_kind: "columns",
        container_id: "grid",
        container_column_index: true,
        container_run_ids: ["a"]
      },
      %{
        container_kind: "columns",
        container_id: "grid",
        container_column_index: -1,
        container_run_ids: ["a"]
      },
      %{
        container_kind: "columns",
        container_id: "grid",
        container_column_index: 9_007_199_254_740_992,
        container_run_ids: ["a"]
      },
      %{
        container_kind: "figure",
        container_id: "figure",
        container_column_index: 0,
        container_run_ids: ["a"]
      },
      %{container_id: "details", container_column_index: 0, container_run_ids: ["a"]}
    ]

    for raw <- invalid do
      assert {:error, :invalid_canvas_run_context} = CanvasRunContext.normalize(raw)

      assert {:error, :invalid_canvas_run_context} =
               CanvasRunContext.map_run([], raw, fn _run ->
                 flunk("map_run must not bypass strict normalization")
               end)
    end
  end

  test "maps an exact section run while preserving its outer shape and metadata" do
    section = %{
      "id" => "section",
      "type" => "section",
      "title" => "Keep",
      "unknown" => %{"keep" => true},
      "children" => [paragraph("opaque")],
      "blocks" => [paragraph("before"), paragraph("a"), paragraph("b"), paragraph("after")]
    }

    original = [section, paragraph("outside")]

    assert {:ok, [updated, outside], :changed} =
             CanvasRunContext.map_run(original, section_context(), fn run ->
               assert Enum.map(run, & &1["id"]) == ["a", "b"]
               {:ok, [paragraph("replacement")], :changed}
             end)

    assert updated["title"] == "Keep"
    assert updated["unknown"] == %{"keep" => true}
    assert updated["children"] == [paragraph("opaque")]
    assert Enum.map(updated["blocks"], & &1["id"]) == ["before", "replacement", "after"]
    assert outside == paragraph("outside")
    assert original == [section, paragraph("outside")]
  end

  test "maps only the selected canonical column and preserves other columns and aliases" do
    grid = %{
      "id" => "grid",
      "type" => "columns",
      "unknown" => [1, 2],
      "blocks" => [paragraph("opaque")],
      "columns" => [
        [paragraph("left")],
        [paragraph("before"), paragraph("a"), paragraph("b"), paragraph("after")],
        %{"opaque" => true},
        "scalar"
      ]
    }

    assert {:ok, [updated], :changed} =
             CanvasRunContext.map_run([grid], columns_context(), fn run ->
               assert Enum.map(run, & &1["id"]) == ["a", "b"]
               {:ok, run ++ [paragraph("new")], :changed}
             end)

    assert updated["unknown"] == [1, 2]
    assert updated["blocks"] == [paragraph("opaque")]
    assert Enum.at(updated["columns"], 0) == [paragraph("left")]

    assert Enum.map(Enum.at(updated["columns"], 1), & &1["id"]) == [
             "before",
             "a",
             "b",
             "new",
             "after"
           ]

    assert Enum.at(updated["columns"], 2) == %{"opaque" => true}
    assert Enum.at(updated["columns"], 3) == "scalar"
  end

  test "resolves typed parents uniquely and never falls back across container kinds" do
    section = section_block()
    columns = columns_block()

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([section], section_context("wrong"), &unchanged/1)

    assert {:error, :canvas_run_container_ambiguous} =
             CanvasRunContext.map_run([section, section], section_context(), &unchanged/1)

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([columns], section_context("grid"), &unchanged/1)

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([section], columns_context("section"), &unchanged/1)

    assert {:error, :canvas_run_container_column_not_found} =
             CanvasRunContext.map_run([columns], columns_context("grid", 9), &unchanged/1)

    assert {:error, :canvas_run_container_ambiguous} =
             CanvasRunContext.map_run([columns, columns], columns_context(), &unchanged/1)
  end

  test "rejects non-contiguous, escaping, ambiguous, and malformed canonical bodies" do
    noncontiguous =
      section_block([paragraph("a"), paragraph("gap"), paragraph("b")])

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run([noncontiguous], section_context(), &unchanged/1)

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run(
               [section_block(), paragraph("outside")],
               section_context("section", ["b", "outside"]),
               &unchanged/1
             )

    ambiguous = section_block([paragraph("a"), paragraph("gap"), paragraph("a")])

    assert {:error, :canvas_run_ambiguous} =
             CanvasRunContext.map_run(
               [ambiguous],
               section_context("section", ["a"]),
               &unchanged/1
             )

    for malformed <- [nil, false, %{}, "scalar"] do
      bad_section = %{"id" => "section", "type" => "section", "blocks" => malformed}

      assert {:error, :canvas_run_container_children_invalid} =
               CanvasRunContext.map_run([bad_section], section_context(), &unchanged/1)

      bad_columns = %{"id" => "grid", "type" => "columns", "columns" => malformed}

      assert {:error, :canvas_run_container_children_invalid} =
               CanvasRunContext.map_run([bad_columns], columns_context(), &unchanged/1)
    end

    selected_scalar = %{
      "id" => "grid",
      "type" => "columns",
      "columns" => [[paragraph("left")], "opaque"]
    }

    assert {:error, :canvas_run_container_children_invalid} =
             CanvasRunContext.map_run([selected_scalar], columns_context(), &unchanged/1)
  end

  test "rejects newly increased collisions while tolerating unchanged legacy duplicates" do
    section = section_block()
    columns = columns_block()

    assert {:error, :canvas_run_id_collision} =
             CanvasRunContext.map_run([section, columns], section_context(), fn run ->
               {:ok, run ++ [paragraph("column-only")], :inserted}
             end)

    assert {:error, :canvas_run_id_collision} =
             CanvasRunContext.map_run([section, columns], columns_context(), fn run ->
               {:ok, run ++ [paragraph("section-only")], :inserted}
             end)

    legacy = [section, paragraph("legacy"), paragraph("legacy")]

    assert {:ok, _updated, :changed} =
             CanvasRunContext.map_run(legacy, section_context(), fn [a, b] ->
               {:ok, [Map.put(a, "text", "changed"), b], :changed}
             end)
  end

  test "finds a Figure through a deep Section to Columns path and changes only its child" do
    figure = %{
      "id" => "figure",
      "type" => "figure",
      "caption" => "Keep",
      "child" => paragraph("figure-child")
    }

    tree =
      section_block([
        %{
          "id" => "grid",
          "type" => "columns",
          "columns" => [
            [paragraph("left")],
            [figure],
            %{"opaque" => figure}
          ]
        }
      ])

    context = %{
      container_kind: "figure",
      container_id: "figure",
      container_run_ids: ["figure-child"]
    }

    assert {:ok, [updated], :changed} =
             CanvasRunContext.map_run([tree], context, fn [child] ->
               {:ok, [Map.put(child, "text", "changed")], :changed}
             end)

    updated_figure =
      get_in(updated, ["blocks", Access.at(0), "columns", Access.at(1), Access.at(0)])

    assert updated_figure["caption"] == "Keep"
    assert updated_figure["child"]["text"] == "changed"

    assert get_in(updated, ["blocks", Access.at(0), "columns", Access.at(2)]) == %{
             "opaque" => figure
           }
  end

  defp section_context(parent_id \\ "section", ids \\ ["a", "b"]) do
    %{container_kind: "section", container_id: parent_id, container_run_ids: ids}
  end

  defp columns_context(parent_id \\ "grid", column_index \\ 1, ids \\ ["a", "b"]) do
    %{
      container_kind: "columns",
      container_id: parent_id,
      container_column_index: column_index,
      container_run_ids: ids
    }
  end

  defp section_block(blocks \\ [paragraph("a"), paragraph("b"), paragraph("section-only")]) do
    %{"id" => "section", "type" => "section", "blocks" => blocks}
  end

  defp columns_block do
    %{
      "id" => "grid",
      "type" => "columns",
      "columns" => [
        [paragraph("left")],
        [paragraph("a"), paragraph("b"), paragraph("column-only")]
      ]
    }
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "text" => id}
  defp unchanged(run), do: {:ok, run, :unchanged}
end
