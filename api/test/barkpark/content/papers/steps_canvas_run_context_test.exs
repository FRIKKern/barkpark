defmodule Barkpark.Content.Papers.StepsCanvasRunContextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.CanvasRunContext

  defp paragraph(id, extra \\ %{}) do
    Map.merge(%{"id" => id, "type" => "paragraph", "text" => id}, extra)
  end

  defp context(parent_id \\ "procedure", row_id \\ "row-a", ids \\ ["a", "b"]) do
    %{
      container_kind: "steps",
      container_id: parent_id,
      container_row_id: row_id,
      container_run_ids: ids
    }
  end

  test "normalization preserves the legacy expandable fingerprint and adds one strict steps shape" do
    legacy = %{container_id: "details", container_run_ids: ["a", "b"]}
    assert {:ok, ^legacy} = CanvasRunContext.normalize(legacy)

    assert {:ok,
            %{
              container_kind: "steps",
              container_id: "procedure",
              container_row_id: "row-a",
              container_run_ids: ["a", "b"]
            }} =
             CanvasRunContext.normalize(%{
               "container_kind" => "steps",
               "container_id" => "procedure",
               "container_row_id" => "row-a",
               "container_run_ids" => ["a", "b"]
             })

    invalid = [
      %{container_id: "details", container_row_id: "row-a", container_run_ids: ["a"]},
      %{container_kind: "steps", container_id: "procedure", container_run_ids: ["a"]},
      %{container_kind: "steps", container_row_id: "row-a", container_run_ids: ["a"]},
      %{
        container_kind: "steps",
        container_id: "procedure",
        container_row_id: "",
        container_run_ids: ["a"]
      },
      %{
        container_kind: "expandable",
        container_id: "details",
        container_run_ids: ["a"]
      },
      %{
        container_kind: "unknown",
        container_id: "procedure",
        container_row_id: "row-a",
        container_run_ids: ["a"]
      }
    ]

    for raw <- invalid do
      assert {:error, :invalid_canvas_run_context} = CanvasRunContext.normalize(raw)

      assert {:error, :invalid_canvas_run_context} =
               CanvasRunContext.map_run([steps_block()], raw, fn _run ->
                 flunk("map_run must not bypass normalization")
               end)
    end
  end

  test "maps one row's contiguous visible segment and preserves every surrounding value" do
    hidden = paragraph("hidden")

    blocks = [
      %{
        "id" => "procedure",
        "type" => "steps",
        "parent-meta" => %{"keep" => true},
        "steps" => [
          %{
            "id" => "row-a",
            "title" => "First",
            "row-meta" => [1, 2],
            "children" => [
              paragraph("before"),
              paragraph("a"),
              paragraph("b"),
              paragraph("after")
            ],
            "blocks" => [hidden]
          },
          %{"id" => "row-b", "title" => "Second", "blocks" => [paragraph("other")]}
        ]
      },
      paragraph("outside")
    ]

    assert {:ok, [updated, outside], :folded} =
             CanvasRunContext.map_run(blocks, context(), fn run ->
               assert Enum.map(run, & &1["id"]) == ["a", "b"]
               {:ok, [paragraph("replacement")], :folded}
             end)

    [row_a, row_b] = updated["steps"]
    assert updated["parent-meta"] == %{"keep" => true}
    assert row_a["row-meta"] == [1, 2]
    assert Enum.map(row_a["children"], & &1["id"]) == ["before", "replacement", "after"]
    assert row_a["blocks"] == [hidden]
    assert row_b == get_in(hd(blocks), ["steps", Access.at(1)])
    assert outside == paragraph("outside")
  end

  test "resolves parent then row uniquely and rejects wrong or ambiguous identity" do
    unique = steps_block()

    assert {:error, :canvas_run_container_not_found} =
             CanvasRunContext.map_run([unique], context("wrong"), &unchanged/1)

    assert {:error, :canvas_run_container_ambiguous} =
             CanvasRunContext.map_run([unique, unique], context(), &unchanged/1)

    assert {:error, :canvas_run_container_row_not_found} =
             CanvasRunContext.map_run([unique], context("procedure", "wrong"), &unchanged/1)

    duplicate_row = update_in(unique["steps"], &(&1 ++ [hd(&1)]))

    assert {:error, :canvas_run_container_row_ambiguous} =
             CanvasRunContext.map_run([duplicate_row], context(), &unchanged/1)
  end

  test "rejects non-contiguous, escaping, hidden and malformed-authoritative row bodies" do
    noncontiguous =
      steps_block([
        %{
          "id" => "row-a",
          "children" => [paragraph("a"), paragraph("gap"), paragraph("b")]
        }
      ])

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run([noncontiguous], context(), &unchanged/1)

    escaping = [steps_block(), paragraph("outside")]

    assert {:error, :canvas_run_not_found} =
             CanvasRunContext.map_run(
               escaping,
               context("procedure", "row-a", ["b", "outside"]),
               &unchanged/1
             )

    for authoritative <- [[], %{"malformed" => true}, "malformed"] do
      hidden =
        steps_block([
          %{
            "id" => "row-a",
            "children" => authoritative,
            "blocks" => [paragraph("a"), paragraph("b")]
          }
        ])

      expected =
        if is_list(authoritative),
          do: :canvas_run_not_found,
          else: :canvas_run_container_children_invalid

      assert {:error, ^expected} =
               CanvasRunContext.map_run([hidden], context(), &unchanged/1)
    end
  end

  test "nil and false children retain their value while the blocks alias is spliced" do
    for absent <- [nil, false] do
      row = %{
        "id" => "row-a",
        "title" => "Legacy",
        "children" => absent,
        "blocks" => [paragraph("a"), paragraph("b")],
        "shadow-meta" => %{"keep" => true}
      }

      assert {:ok, [updated], :folded} =
               CanvasRunContext.map_run([steps_block([row])], context(), fn run ->
                 {:ok, run ++ [paragraph("new")], :folded}
               end)

      updated_row = hd(updated["steps"])
      assert updated_row["children"] == absent
      assert Enum.map(updated_row["blocks"], & &1["id"]) == ["a", "b", "new"]
      assert updated_row["shadow-meta"] == %{"keep" => true}
      refute is_list(updated_row["children"])
    end
  end

  test "finds nested steps through visible steps, expandable and section bodies only" do
    nested = %{
      "id" => "outer-procedure",
      "type" => "steps",
      "steps" => [
        %{
          "id" => "outer-row",
          "children" => [
            %{
              "id" => "details",
              "type" => "expandable",
              "children" => [
                %{
                  "id" => "section",
                  "type" => "section",
                  "blocks" => [steps_block()]
                }
              ],
              "blocks" => [steps_block([%{"id" => "row-a", "children" => [paragraph("shadow")]}])]
            }
          ]
        }
      ]
    }

    assert {:ok, [updated], :folded} =
             CanvasRunContext.map_run([nested], context(), fn run ->
               {:ok, Enum.map(run, &Map.put(&1, "nested", true)), :folded}
             end)

    visible_steps =
      updated["steps"]
      |> hd()
      |> Map.fetch!("children")
      |> hd()
      |> Map.fetch!("children")
      |> hd()
      |> Map.fetch!("blocks")
      |> hd()

    assert Enum.all?(hd(visible_steps["steps"])["children"], & &1["nested"])

    assert get_in(updated, ["steps", Access.at(0), "children", Access.at(0), "blocks"]) ==
             [steps_block([%{"id" => "row-a", "children" => [paragraph("shadow")]}])]
  end

  test "collision accounting includes row shadow lists but tolerates legacy duplicates" do
    with_shadow =
      steps_block([
        %{
          "id" => "row-a",
          "children" => [paragraph("a"), paragraph("b")],
          "blocks" => [paragraph("shadow")]
        }
      ])

    assert {:error, :canvas_run_id_collision} =
             CanvasRunContext.map_run([with_shadow], context(), fn run ->
               {:ok, run ++ [paragraph("shadow")], :folded}
             end)

    legacy = [with_shadow, paragraph("legacy"), paragraph("legacy")]

    assert {:ok, _updated, :folded} =
             CanvasRunContext.map_run(legacy, context(), fn [a, b] ->
               {:ok, [Map.put(a, "text", "changed"), b], :folded}
             end)
  end

  defp steps_block(rows \\ nil) do
    %{
      "id" => "procedure",
      "type" => "steps",
      "steps" => rows || [%{"id" => "row-a", "children" => [paragraph("a"), paragraph("b")]}]
    }
  end

  defp unchanged(run), do: {:ok, run, :unchanged}
end
