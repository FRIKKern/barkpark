defmodule BarkparkWeb.Studio.PaperEditor.StepsBlockLookupTest do
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "nested controls resolve blocks inside step rows, not the rows themselves" do
    child = %{"id" => "child", "type" => "number", "value" => 4}

    blocks = [
      nil,
      %{
        "id" => "steps",
        "type" => "steps",
        "steps" => [
          nil,
          %{"id" => "row", "children" => [child]}
        ]
      }
    ]

    assert Blocks.find_paper_block(blocks, "child") == child
    assert Blocks.find_paper_block(blocks, "row") == nil
  end

  test "lookup respects authoritative body aliases at every nesting depth" do
    child = %{"id" => "child", "type" => "number"}

    for children <- [[], "invalid", %{}] do
      row = %{"id" => "row", "children" => children, "blocks" => [child]}
      blocks = [%{"id" => "steps", "type" => "steps", "steps" => [row]}]
      assert Blocks.find_paper_block(blocks, "child") == nil
      assert Blocks.container_children(Map.put(row, "type", "expandable")) == []
    end

    for children <- [nil, false] do
      row = %{"id" => "row", "children" => children, "blocks" => [child]}
      blocks = [%{"id" => "steps", "type" => "steps", "steps" => [row]}]
      assert Blocks.find_paper_block(blocks, "child") == child
    end
  end
end
