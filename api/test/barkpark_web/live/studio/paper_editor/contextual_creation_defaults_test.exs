defmodule BarkparkWeb.Studio.PaperEditor.ContextualCreationDefaultsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Patch, Render}
  alias BarkparkWeb.Studio.StudioLive.Blocks

  for type <- ~w(paper-links expandable bar-chart) do
    test "#{type} constructor stays typed and accepts contextual edits without losing metadata" do
      type = unquote(type)
      block = Blocks.default_block(type, "created")
      assert block["id"] == "created"
      assert block["type"] == type
      refute Render.render_block(block, %{style: :article}) =~ "unsupported"

      block = with_nested_metadata(block) |> Map.put("vendor", %{"keep" => [1, 2]})
      sibling = %{"id" => "sibling", "type" => "future-block", "opaque" => %{"keep" => true}}
      patch = Blocks.build_block_patch(block, edit_params(type))

      assert {:ok, [edited, ^sibling]} =
               Patch.apply_patch([block, sibling], %{
                 "op" => "patch-block",
                 "id" => block["id"],
                 "patch" => patch
               })

      assert edited["type"] == type
      assert edited["vendor"] == block["vendor"]
      assert_nested_metadata(edited, block)
    end
  end

  test "expandable children have deterministic identities distinct from their parent and other seeds" do
    first = Blocks.default_block("expandable", "one")
    second = Blocks.default_block("expandable", "two")
    assert [%{"id" => "one-0", "type" => "paragraph"}] = first["children"]
    assert [%{"id" => "two-0", "type" => "paragraph"}] = second["children"]
    refute Map.has_key?(first, "blocks")
  end

  test "bar-chart sample rows are nonempty numeric data scaled by their current maximum" do
    block = Blocks.default_block("bar-chart", "chart")
    assert block["values"] == true
    refute Map.has_key?(block, "max")

    assert block["bars"] == [
             %{"label" => "Sample A", "value" => 10},
             %{"label" => "Sample B", "value" => 5}
           ]

    html = Render.render_block(block, %{style: :article})
    assert html =~ "Sample A"
    assert html =~ "width:100%"
    assert html =~ "width:50%"
  end

  test "paper-links does not invent a destination and uses existing add-reference action" do
    block = Blocks.default_block("paper-links", "links")
    assert block["refs"] == []

    assert Blocks.build_block_patch(block, %{"ref-count" => "0", "ref-action" => "add"}) == %{
             "refs" => [""]
           }
  end

  defp with_nested_metadata(%{"type" => "paper-links"} = block),
    do: Map.put(block, "refs", [%{"slug" => "existing", "vendor" => %{"nested" => true}}])

  defp with_nested_metadata(%{"type" => "expandable"} = block),
    do: update_in(block, ["children", Access.at(0)], &Map.put(&1, "vendor", ["nested"]))

  defp with_nested_metadata(%{"type" => "bar-chart"} = block),
    do: update_in(block, ["bars", Access.at(0)], &Map.put(&1, "vendor", %{"nested" => true}))

  defp edit_params("paper-links"),
    do: %{"title" => "Edited", "ref-count" => "1", "ref-0-slug" => "edited"}

  defp edit_params("expandable"), do: %{"summary" => "Edited", "open" => "true"}

  defp edit_params("bar-chart"),
    do: %{
      "values" => "true",
      "bar-count" => "2",
      "bar-0-label" => "Edited",
      "bar-0-value" => "12"
    }

  defp assert_nested_metadata(%{"type" => "paper-links"} = edited, original),
    do: assert(hd(edited["refs"])["vendor"] == hd(original["refs"])["vendor"])

  defp assert_nested_metadata(%{"type" => "expandable"} = edited, original),
    do: assert(edited["children"] == original["children"])

  defp assert_nested_metadata(%{"type" => "bar-chart"} = edited, original) do
    assert hd(edited["bars"])["vendor"] == hd(original["bars"])["vendor"]
    assert Enum.at(edited["bars"], 1) == Enum.at(original["bars"], 1)
  end
end
