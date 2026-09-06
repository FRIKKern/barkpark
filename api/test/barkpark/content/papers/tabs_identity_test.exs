defmodule Barkpark.Content.Papers.TabsIdentityTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps

  test "projects stable tab-row and canonical descendant identities globally" do
    opaque = [%{"type" => "paragraph", "text" => "Opaque"}]

    blocks = [
      %{"id" => "switcher-tab-0", "type" => "paragraph", "text" => "Reserved"},
      %{
        "id" => "switcher",
        "type" => "tabs",
        "unknown" => %{"keep" => true},
        "tabs" => [
          %{
            "title" => "First",
            "meta" => 7,
            "blocks" => [%{"type" => "paragraph", "text" => "Visible"}],
            "children" => opaque,
            "content" => opaque
          },
          %{"id" => "switcher-tab-1", "title" => "Second", "blocks" => []}
        ]
      }
    ]

    [outside, projected] = BlockOps.ensure_block_ids(blocks)
    [first, second] = projected["tabs"]

    assert outside == hd(blocks)
    assert first["id"] == "switcher-tab-0-1"

    assert first["blocks"] == [
             %{"id" => "switcher-tab-0-1-0", "type" => "paragraph", "text" => "Visible"}
           ]

    assert first["children"] == opaque
    assert first["content"] == opaque
    assert first["meta"] == 7
    assert second == Enum.at(hd(tl(blocks))["tabs"], 1)
    assert projected["unknown"] == %{"keep" => true}
    assert BlockOps.ensure_block_ids([outside, projected]) == [outside, projected]

    reordered = Map.put(projected, "tabs", [second, first])
    assert BlockOps.ensure_block_ids([outside, reordered]) == [outside, reordered]
  end

  test "retains malformed tab collections and rows byte-identical" do
    for tabs <- [%{}, "legacy", true, 7] do
      block = %{"id" => "switcher", "type" => "tabs", "tabs" => tabs}
      assert BlockOps.ensure_block_ids([block]) == [block]
    end

    rows = [nil, "legacy", 7, %{"id" => "row", "title" => "Kept", "blocks" => false}]
    block = %{"id" => "switcher", "type" => "tabs", "tabs" => rows}
    assert BlockOps.ensure_block_ids([block]) == [block]
  end

  test "malformed tabs never expose a generic top-level blocks alias" do
    for tabs <- [%{}, "legacy", true, 7] do
      hidden = [%{"id" => "duplicate", "type" => "paragraph"}, %{"type" => "paragraph"}]

      blocks = [
        %{"id" => "duplicate", "type" => "paragraph"},
        %{"id" => "switcher", "type" => "tabs", "tabs" => tabs, "blocks" => hidden}
      ]

      assert BlockOps.ensure_block_ids(blocks) == blocks
      assert {:ok, ^blocks} = BlockOps.project_block_ids_safely(blocks)
    end
  end

  test "canonical descendant ids avoid identities authored outside their tab" do
    blocks = [
      %{"id" => "switcher-tab-0-0", "type" => "paragraph", "text" => "Reserved"},
      %{
        "id" => "switcher",
        "type" => "tabs",
        "tabs" => [%{"id" => "switcher-tab-0", "blocks" => [%{"type" => "paragraph"}]}]
      }
    ]

    [outside, projected] = BlockOps.ensure_block_ids(blocks)
    child = projected |> Map.fetch!("tabs") |> hd() |> Map.fetch!("blocks") |> hd()

    assert outside["id"] == "switcher-tab-0-0"
    assert child["id"] == "switcher-tab-0-0-1"
  end

  test "scalar entries in a canonical blocks list are retained while map descendants project" do
    block = %{
      "id" => "switcher",
      "type" => "tabs",
      "tabs" => [%{"blocks" => ["legacy", nil, 7, %{"type" => "paragraph"}]}]
    }

    [projected] = BlockOps.ensure_block_ids([block])
    [row] = projected["tabs"]

    assert row["id"] == "switcher-tab-0"

    assert row["blocks"] == [
             "legacy",
             nil,
             7,
             %{"id" => "switcher-tab-0-3", "type" => "paragraph"}
           ]
  end

  test "projects nested canonical blocks but leaves children, content, and code-tabs opaque" do
    opaque = [%{"type" => "paragraph", "text" => "Hidden"}]

    block = %{
      "id" => "switcher",
      "type" => "tabs",
      "tabs" => [
        %{
          "blocks" => [
            %{
              "type" => "tabs",
              "tabs" => [%{"blocks" => [%{"type" => "paragraph", "text" => "Deep"}]}]
            },
            %{"type" => "code-tabs", "tabs" => [%{"blocks" => opaque}]}
          ],
          "children" => opaque,
          "content" => opaque
        }
      ]
    }

    [projected] = BlockOps.ensure_block_ids([block])
    [row] = projected["tabs"]
    [nested, code_tabs] = row["blocks"]
    [nested_row] = nested["tabs"]

    assert row["id"] == "switcher-tab-0"
    assert nested["id"] == "switcher-tab-0-0"
    assert nested_row["id"] == "switcher-tab-0-0-tab-0"
    assert hd(nested_row["blocks"])["id"] == "switcher-tab-0-0-tab-0-0"
    assert code_tabs["id"] == "switcher-tab-0-1"
    assert code_tabs["tabs"] == Enum.at(block["tabs"] |> hd() |> Map.fetch!("blocks"), 1)["tabs"]
    assert row["children"] == opaque
    assert row["content"] == opaque
  end

  test "safe projection rejects canonical row and descendant duplicates but ignores opaque ids" do
    duplicate_row = [
      %{"id" => "same", "type" => "paragraph"},
      %{"id" => "tabs", "type" => "tabs", "tabs" => [%{"id" => "same", "blocks" => []}]}
    ]

    assert {:error, {:duplicate_id, "same"}} =
             BlockOps.project_block_ids_safely(duplicate_row)

    duplicate_child = [
      %{"id" => "same", "type" => "paragraph"},
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [%{"id" => "row", "blocks" => [%{"id" => "same", "type" => "paragraph"}]}]
      }
    ]

    assert {:error, {:duplicate_id, "same"}} =
             BlockOps.project_block_ids_safely(duplicate_child)

    opaque_duplicate = [
      %{"id" => "same", "type" => "paragraph"},
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [%{"id" => "row", "blocks" => [], "children" => [%{"id" => "same"}]}]
      }
    ]

    assert {:ok, ^opaque_duplicate} = BlockOps.project_block_ids_safely(opaque_duplicate)
  end
end
