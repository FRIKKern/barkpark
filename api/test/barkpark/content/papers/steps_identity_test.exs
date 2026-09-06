defmodule Barkpark.Content.Papers.StepsIdentityTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps

  test "projects stable row and child identities without rebuilding authored maps" do
    shadow = [%{"type" => "paragraph", "text" => "Hidden legacy body"}]

    blocks = [
      %{
        "id" => "procedure",
        "type" => "steps",
        "unknown" => %{"keep" => true},
        "steps" => [
          %{
            "title" => "Prepare",
            "custom" => 7,
            "children" => [%{"type" => "paragraph", "text" => "Visible"}],
            "blocks" => shadow
          },
          %{"id" => "procedure-step-0", "title" => "Existing", "blocks" => []}
        ]
      }
    ]

    [projected] = BlockOps.ensure_block_ids(blocks)
    [first, second] = projected["steps"]
    assert first["id"] == "procedure-step-0-1"
    assert second["id"] == "procedure-step-0"

    assert first["children"] == [
             %{"id" => "procedure-step-0-1-0", "type" => "paragraph", "text" => "Visible"}
           ]

    assert first["blocks"] == shadow
    assert first["custom"] == 7
    assert projected["unknown"] == %{"keep" => true}
    assert BlockOps.ensure_block_ids([projected]) == [projected]
    assert BlockOps.ensure_block_ids(blocks) == [projected]

    reordered = Map.put(projected, "steps", [second, first])
    assert BlockOps.ensure_block_ids([reordered]) == [reordered]
  end

  test "malformed rows and authored metadata are retained rather than interpreted as blocks" do
    rows = [
      nil,
      "legacy",
      7,
      %{"id" => "row", "type" => "unknown-row-metadata", "content" => "keep"}
    ]

    block = %{"id" => "p", "type" => "steps", "steps" => rows}
    assert BlockOps.ensure_block_ids([block]) == [block]
  end

  test "only the reader-visible list receives child identities" do
    child = %{"type" => "paragraph", "text" => "Legacy"}

    for children <- [[], %{}, "", "invalid", true, 0] do
      block = %{
        "id" => "p",
        "type" => "steps",
        "steps" => [
          %{"id" => "row", "children" => children, "blocks" => [child]}
        ]
      }

      assert BlockOps.ensure_block_ids([block]) == [block]
    end

    for absent <- [nil, false] do
      block = %{
        "id" => "p",
        "type" => "steps",
        "steps" => [
          %{"id" => "row", "children" => absent, "blocks" => [child]}
        ]
      }

      [projected] = BlockOps.ensure_block_ids([block])
      assert hd(projected["steps"])["blocks"] == [Map.put(child, "id", "row-0")]
      assert hd(projected["steps"])["children"] == absent
    end
  end

  test "expandable projection obeys the same authoritative body boundary" do
    child = %{"type" => "paragraph", "text" => "Hidden"}

    for children <- [[], %{}, "", "invalid", true, 0] do
      block = %{
        "id" => "details",
        "type" => "expandable",
        "children" => children,
        "blocks" => [child]
      }

      assert BlockOps.ensure_block_ids([block]) == [block]
    end
  end

  test "nested steps and legacy row bodies project recursively without an outer items alias" do
    block = %{
      "id" => "p",
      "type" => "steps",
      "steps" => [
        %{
          "blocks" => [
            %{
              "type" => "steps",
              "steps" => [
                %{"children" => [%{"type" => "paragraph", "text" => "Nested"}]}
              ]
            }
          ]
        }
      ],
      "items" => [%{"blocks" => [%{"type" => "paragraph", "text" => "Shadow"}]}]
    }

    [projected] = BlockOps.ensure_block_ids([block])
    row = hd(projected["steps"])
    nested = hd(row["blocks"])
    nested_row = hd(nested["steps"])
    assert row["id"] == "p-step-0"
    assert nested["id"] == "p-step-0-0"
    assert nested_row["id"] == "p-step-0-0-step-0"
    assert hd(nested_row["children"])["id"] == "p-step-0-0-step-0-0"
    assert projected["items"] == block["items"]
  end
end
