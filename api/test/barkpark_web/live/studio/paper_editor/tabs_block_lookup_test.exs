defmodule BarkparkWeb.Studio.PaperEditor.TabsBlockLookupTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "resolves canonical tab descendants recursively but never row identities" do
    child = %{"id" => "child", "type" => "number", "value" => 4}

    blocks = [
      nil,
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [
          nil,
          %{
            "id" => "row",
            "blocks" => [
              %{
                "id" => "nested",
                "type" => "tabs",
                "tabs" => [%{"id" => "nested-row", "blocks" => [child]}]
              }
            ]
          }
        ]
      }
    ]

    assert Blocks.find_paper_block(blocks, "child") == child
    assert Blocks.find_paper_block(blocks, "row") == nil
    assert Blocks.find_paper_block(blocks, "nested-row") == nil
  end

  test "children, content, malformed tabs and code-tabs remain opaque" do
    child = %{"id" => "child", "type" => "number"}

    blocks = [
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [%{"id" => "row", "blocks" => [], "children" => [child], "content" => [child]}]
      },
      %{"id" => "bad", "type" => "tabs", "tabs" => %{"blocks" => [child]}},
      %{"id" => "code-tabs", "type" => "code-tabs", "tabs" => [%{"blocks" => [child]}]}
    ]

    assert Blocks.find_paper_block(blocks, "child") == nil
  end
end
