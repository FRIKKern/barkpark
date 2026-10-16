defmodule Barkpark.Content.ValidationPortableTextScopeTest do
  @moduledoc """
  The "Sanity Portable Text block, not a PortableDoc block" finding
  (task-2d96f71d3fe52ee7) belongs to a field the block editor edits. A Classic
  richText stores Portable Text (owner ruling #44) and the Classic editor opens
  and saves it, so Portable Text there, at the top level or inside a
  page-builder item, is not an error that blocks publishing
  (task-e24e33a2a1a4fe10).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.Validation

  @pt [
    %{
      "_type" => "block",
      "_key" => "a1",
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => "a1s0", "text" => "Hei", "marks" => []}]
    }
  ]

  defp schema(fields), do: %SchemaDefinition{name: "doc", title: "Doc", fields: fields}

  defp codes(%{errors: errors}),
    do: errors |> inspect() |> then(&Regex.scan(~r/not a PortableDoc block/, &1)) |> length()

  test "a Classic richText holding Portable Text has no finding" do
    s = schema([%{"name" => "body", "type" => "richText"}])
    assert codes(Validation.check_tree(%{"body" => @pt}, "T", s)) == 0
  end

  test "a page-builder item's Classic richText holding Portable Text has no finding" do
    s =
      schema([
        %{
          "name" => "sections",
          "type" => "arrayOf",
          "of" => [
            %{
              "name" => "contentSection",
              "type" => "composite",
              "fields" => [%{"name" => "body", "type" => "richText"}]
            }
          ]
        }
      ])

    content = %{"sections" => [%{"_type" => "contentSection", "_key" => "s1", "body" => @pt}]}
    assert codes(Validation.check_tree(content, "T", s)) == 0
  end

  test "a block-editor richText holding Portable Text still has the finding" do
    s = schema([%{"name" => "body", "type" => "richText", "editor" => "blocks"}])
    assert codes(Validation.check_tree(%{"body" => @pt}, "T", s)) == 1
  end
end
