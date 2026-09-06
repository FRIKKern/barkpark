defmodule Barkpark.Content.Papers.TabsCanvasRunContextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.CanvasRunContext

  test "normalizes one strict tabs row context without changing the legacy expandable shape" do
    legacy = %{container_id: "details", container_run_ids: ["a", "b"]}
    assert {:ok, ^legacy} = CanvasRunContext.normalize(legacy)

    assert {:ok,
            %{
              container_kind: "tabs",
              container_id: "switcher",
              container_row_id: "tab-a",
              container_run_ids: ["a", "b"]
            }} =
             CanvasRunContext.normalize(%{
               "container_kind" => "tabs",
               "container_id" => "switcher",
               "container_row_id" => "tab-a",
               "container_run_ids" => ["a", "b"]
             })

    invalid = [
      %{container_kind: "tabs", container_id: "switcher", container_run_ids: ["a"]},
      %{container_kind: "tabs", container_row_id: "tab-a", container_run_ids: ["a"]},
      %{
        container_kind: "tabs",
        container_id: "switcher",
        container_row_id: "",
        container_run_ids: ["a"]
      },
      %{
        container_kind: "code-tabs",
        container_id: "switcher",
        container_row_id: "tab-a",
        container_run_ids: ["a"]
      }
    ]

    for raw <- invalid do
      assert {:error, :invalid_canvas_run_context} = CanvasRunContext.normalize(raw)

      assert {:error, :invalid_canvas_run_context} =
               CanvasRunContext.map_run([tabs_block()], raw, fn _run ->
                 flunk("map_run must not bypass normalization")
               end)
    end
  end

  test "maps one canonical tab row segment and preserves all surrounding and opaque values" do
    hidden = [paragraph("opaque")]

    blocks = [
      %{
        "id" => "switcher",
        "type" => "tabs",
        "parent-meta" => %{"keep" => true},
        "tabs" => [
          %{
            "id" => "tab-a",
            "title" => "First",
            "row-meta" => [1, 2],
            "blocks" => [
              paragraph("before"),
              paragraph("a"),
              paragraph("b"),
              paragraph("after")
            ],
            "children" => hidden,
            "content" => hidden
          },
          %{"id" => "tab-b", "title" => "Second", "blocks" => [paragraph("other")]}
        ]
      },
      paragraph("outside")
    ]

    assert {:ok, [updated, outside], :folded} =
             CanvasRunContext.map_run(blocks, context(), fn run ->
               assert Enum.map(run, & &1["id"]) == ["a", "b"]
               {:ok, [paragraph("replacement")], :folded}
             end)

    [tab_a, tab_b] = updated["tabs"]
    assert updated["parent-meta"] == %{"keep" => true}
    assert tab_a["row-meta"] == [1, 2]
    assert Enum.map(tab_a["blocks"], & &1["id"]) == ["before", "replacement", "after"]
    assert tab_a["children"] == hidden
    assert tab_a["content"] == hidden
    assert tab_b == get_in(hd(blocks), ["tabs", Access.at(1)])
    assert outside == paragraph("outside")
  end

  test "resolves parent and row uniquely" do
    unique = tabs_block()

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([unique], context("wrong"), &unchanged/1)

    assert {:error, :canvas_run_container_ambiguous} =
             CanvasRunContext.map_run([unique, unique], context(), &unchanged/1)

    assert {:error, :canvas_run_container_row_not_found} =
             CanvasRunContext.map_run([unique], context("switcher", "wrong"), &unchanged/1)

    duplicate_row = update_in(unique["tabs"], &(&1 ++ [hd(&1)]))

    assert {:error, :canvas_run_container_row_ambiguous} =
             CanvasRunContext.map_run([duplicate_row], context(), &unchanged/1)
  end

  test "rejects non-contiguous, escaping, ambiguous, and malformed canonical tab runs" do
    noncontiguous =
      tabs_block([
        %{
          "id" => "tab-a",
          "blocks" => [paragraph("a"), paragraph("gap"), paragraph("b")]
        }
      ])

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run([noncontiguous], context(), &unchanged/1)

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run(
               [tabs_block(), paragraph("outside")],
               context("switcher", "tab-a", ["b", "outside"]),
               &unchanged/1
             )

    ambiguous =
      tabs_block([
        %{
          "id" => "tab-a",
          "blocks" => [paragraph("a"), paragraph("gap"), paragraph("a")]
        }
      ])

    assert {:error, :canvas_run_ambiguous} =
             CanvasRunContext.map_run(
               [ambiguous],
               context("switcher", "tab-a", ["a"]),
               &unchanged/1
             )

    for malformed <- [nil, false, %{"not" => "a list"}, "scalar"] do
      bad_parent = %{"id" => "switcher", "type" => "tabs", "tabs" => malformed}

      assert {:error, :canvas_run_container_children_invalid} =
               CanvasRunContext.map_run([bad_parent], context(), &unchanged/1)

      bad_row = tabs_block([%{"id" => "tab-a", "blocks" => malformed}])

      assert {:error, :canvas_run_container_children_invalid} =
               CanvasRunContext.map_run([bad_row], context(), &unchanged/1)
    end
  end

  test "finds nested tabs through canonical tabs, section, expandable, and steps bodies" do
    target = tabs_block()

    nested = %{
      "id" => "outer-tabs",
      "type" => "tabs",
      "tabs" => [
        %{
          "id" => "outer-tab",
          "blocks" => [
            %{
              "id" => "section",
              "type" => "section",
              "blocks" => [
                %{
                  "id" => "details",
                  "type" => "expandable",
                  "children" => [
                    %{
                      "id" => "procedure",
                      "type" => "steps",
                      "steps" => [%{"id" => "step", "blocks" => [target]}]
                    }
                  ],
                  "blocks" => [
                    tabs_block([%{"id" => "tab-a", "blocks" => [paragraph("shadow")]}])
                  ]
                }
              ]
            }
          ],
          "children" => [target],
          "content" => [target]
        }
      ]
    }

    assert {:ok, [updated], :changed} =
             CanvasRunContext.map_run([nested], context(), fn run ->
               {:ok, Enum.map(run, &Map.put(&1, "nested", true)), :changed}
             end)

    target_row =
      updated["tabs"]
      |> hd()
      |> Map.fetch!("blocks")
      |> hd()
      |> Map.fetch!("blocks")
      |> hd()
      |> Map.fetch!("children")
      |> hd()
      |> Map.fetch!("steps")
      |> hd()
      |> Map.fetch!("blocks")
      |> hd()
      |> Map.fetch!("tabs")
      |> hd()

    assert Enum.all?(target_row["blocks"], & &1["nested"])
    assert get_in(updated, ["tabs", Access.at(0), "children"]) == [target]
    assert get_in(updated, ["tabs", Access.at(0), "content"]) == [target]

    assert get_in(updated, [
             "tabs",
             Access.at(0),
             "blocks",
             Access.at(0),
             "blocks",
             Access.at(0),
             "blocks"
           ]) == [tabs_block([%{"id" => "tab-a", "blocks" => [paragraph("shadow")]}])]
  end

  test "collision accounting includes all tab row identities and canonical descendants only" do
    hidden = [paragraph("opaque")]

    rows = [
      %{
        "id" => "tab-a",
        "blocks" => [paragraph("a"), paragraph("b")],
        "children" => hidden,
        "content" => hidden
      },
      %{"id" => "tab-b", "blocks" => [paragraph("canonical")]}
    ]

    for colliding_id <- ["tab-a", "tab-b", "canonical"] do
      assert {:error, :canvas_run_id_collision} =
               CanvasRunContext.map_run([tabs_block(rows)], context(), fn run ->
                 {:ok, run ++ [paragraph(colliding_id)], :inserted}
               end)
    end

    assert {:ok, _updated, :inserted} =
             CanvasRunContext.map_run([tabs_block(rows)], context(), fn run ->
               {:ok, run ++ [paragraph("opaque")], :inserted}
             end)
  end

  test "does not reject unchanged legacy collisions involving tab rows" do
    block = tabs_block()
    legacy = [block, paragraph("tab-a"), paragraph("tab-a")]

    assert {:ok, _updated, :changed} =
             CanvasRunContext.map_run(legacy, context(), fn [a, b] ->
               {:ok, [Map.put(a, "text", "changed"), b], :changed}
             end)
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "text" => id}

  defp context(parent_id \\ "switcher", row_id \\ "tab-a", ids \\ ["a", "b"]) do
    %{
      container_kind: "tabs",
      container_id: parent_id,
      container_row_id: row_id,
      container_run_ids: ids
    }
  end

  defp tabs_block(rows \\ nil) do
    %{
      "id" => "switcher",
      "type" => "tabs",
      "tabs" => rows || [%{"id" => "tab-a", "blocks" => [paragraph("a"), paragraph("b")]}]
    }
  end

  defp unchanged(run), do: {:ok, run, :unchanged}
end
