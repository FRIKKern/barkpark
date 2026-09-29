defmodule BarkparkWeb.Studio.PaperEditor.ContextualOptionalPreservationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias Barkpark.PortableDoc.Render

  for {type, key} <- [{"bar-chart", "max"}, {"paper-links", "layout"}] do
    test "#{type}: unchanged blank controls preserve exact optional source shapes" do
      type = unquote(type)
      key = unquote(key)

      for attrs <- [
            %{},
            %{key => nil},
            %{key => ""},
            %{key => "  "},
            %{key => %{"future" => [1]}},
            %{key => false}
          ] do
        block = Map.merge(Blocks.default_block(type, "sample"), attrs)
        patch = Blocks.build_block_patch(block, %{key => "", "values" => "true"})
        refute Map.has_key?(patch, key)
        assert Map.merge(block, patch) == block

        assert render_component(&PaperEditor.paper_block_fields/1, %{block: block}) =~
                 ~s(name="#{key}")
      end
    end

    test "#{type}: omission, real edits and clears preserve unrelated metadata" do
      type = unquote(type)
      key = unquote(key)
      value = if type == "bar-chart", do: "12.5", else: "compact"
      expected = if type == "bar-chart", do: 12.5, else: "compact"
      block = Blocks.default_block(type, "sample") |> Map.put("vendor", %{"nested" => true})
      refute Map.has_key?(Blocks.build_block_patch(block, %{}), key)
      patch = Blocks.build_block_patch(block, %{key => value})
      assert patch[key] == expected
      edited = Map.merge(block, patch)
      assert edited["vendor"] == block["vendor"]
      assert Map.fetch!(Blocks.build_block_patch(edited, %{key => ""}), key) == nil
    end
  end

  test "equivalent numeric and layout submissions retain source representation" do
    for value <- [12, 12.0, "12", "12.00", " 12 "] do
      block = Blocks.default_block("bar-chart", "sample") |> Map.put("max", value)
      refute Map.has_key?(Blocks.build_block_patch(block, %{"max" => "12.0"}), "max")
      refute Map.has_key?(Blocks.build_block_patch(block, %{"max" => "invalid"}), "max")
    end

    block = Blocks.default_block("paper-links", "sample") |> Map.put("layout", " future-layout ")
    refute Map.has_key?(Blocks.build_block_patch(block, %{"layout" => "future-layout"}), "layout")
  end

  test "chart title remains stored metadata, not a misleading reader-facing control" do
    block = Blocks.default_block("bar-chart", "sample") |> Map.put("title", "Legacy title")
    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})
    refute html =~ ~s(name="title")
    refute Render.render_block(block, %{style: :article}) =~ "Legacy title"
    patch = Blocks.build_block_patch(block, %{"title" => "", "values" => "true"})
    refute Map.has_key?(patch, "title")
    assert Map.merge(block, patch) == block
  end

  test "whole chart checkbox projection preserves untouched visibility source shapes" do
    for attrs <- [
          %{},
          %{"values" => nil},
          %{"values" => false},
          %{"values" => "true"},
          %{"values" => ""},
          %{"values" => 0},
          %{"values" => %{"future" => true}},
          %{"values" => true}
        ] do
      block =
        Blocks.default_block("bar-chart", "chart") |> Map.delete("values") |> Map.merge(attrs)

      params = if block["values"] == true, do: %{"values" => "true"}, else: %{}
      params = Map.put(params, "bar-count", "2")
      patch = Blocks.build_block_patch(block, params)
      refute Map.has_key?(patch, "values")
      assert Map.merge(block, patch) === block
      refute Map.has_key?(Blocks.build_block_patch(block, %{"max" => "20"}), "values")

      toggle = if block["values"] == true, do: "false", else: "true"

      assert Blocks.build_block_patch(block, Map.put(params, "values", toggle))["values"] ==
               (toggle == "true")
    end

    block = Blocks.default_block("bar-chart", "chart")
    assert Blocks.build_block_patch(block, %{"bar-count" => "2"})["values"] == false
  end

  test "unchanged or equivalent numeric rows keep authored representations and metadata" do
    for value <- [12, 12.0, "12", "12.00", "1.2e1"] do
      row = %{"label" => "Before", "value" => value, "vendor" => %{"keep" => [1]}}
      block = %{"type" => "bar-chart", "bars" => [row]}
      params = %{"bar-count" => "1", "bar-0-label" => "After", "bar-0-value" => "12"}
      assert Blocks.build_block_patch(block, params)["bars"] === [Map.put(row, "label", "After")]

      assert Blocks.build_block_patch(block, Map.put(params, "bar-0-value", "14.5"))["bars"] === [
               Map.merge(row, %{"label" => "After", "value" => 14.5})
             ]
    end
  end

  test "absent, null and empty chart labels survive whole forms and unrelated edits" do
    for attrs <- [%{}, %{"label" => nil}, %{"label" => ""}] do
      row = Map.merge(%{"value" => "12.00", "vendor" => %{"nested" => [1, nil]}}, attrs)
      sibling = %{"label" => "Keep", "value" => "6", "vendor" => %{"opaque" => true}}
      block = %{"type" => "bar-chart", "bars" => [row, sibling]}

      params = %{
        "bar-count" => "2",
        "bar-0-label" => "",
        "bar-0-value" => "12.00",
        "bar-1-label" => "Keep",
        "bar-1-value" => "6"
      }

      assert Map.merge(block, Blocks.build_block_patch(block, params)) === block

      assert Blocks.build_block_patch(block, Map.put(params, "bar-1-label", "Changed"))["bars"] ===
               [row, Map.put(sibling, "label", "Changed")]

      assert Blocks.build_block_patch(block, Map.put(params, "bar-0-value", "15"))["bars"] === [
               Map.put(row, "value", 15),
               sibling
             ]

      edited = Map.put(row, "label", "Authored label")

      assert Blocks.build_block_patch(block, Map.put(params, "bar-0-label", "Authored label"))[
               "bars"
             ] === [edited, sibling]

      assert Blocks.build_block_patch(Map.put(block, "bars", [edited, sibling]), params)["bars"] ===
               [Map.put(row, "label", ""), sibling]
    end
  end
end
