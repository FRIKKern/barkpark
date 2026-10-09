defmodule BarkparkWeb.Components.VisibleWhenParentScopeTest do
  @moduledoc """
  task-9905a69475b1ff3b: inside a `links` array, `url` is visible only when THIS
  item's `kind` is "url" (`"scope": "parent"`). The default scope reads the
  document, which Studio now hands every item's composite as `root`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Components.Fields.ArrayField

  defp links_field(predicate) do
    {:ok, %{fields: [field]}} =
      SchemaDefinition.parse(%{
        "name" => "linkset",
        "fields" => [
          %{
            "name" => "links",
            "type" => "arrayOf",
            "of" => %{
              "type" => "composite",
              "fields" => [
                %{"name" => "kind", "type" => "string"},
                %{"name" => "url", "type" => "string", "visibleWhen" => predicate}
              ]
            }
          }
        ]
      })

    field
  end

  @items [%{"kind" => "url", "url" => "https://a.example"}, %{"kind" => "doc"}]
  # The document's own `kind` is "doc": a document-scoped predicate hides `url`
  # in every item, a parent-scoped one only where the item says "doc".
  @root %{"kind" => "doc", "links" => @items}
  @pred %{"field" => "kind", "operator" => "eq", "value" => "url"}

  defp url_inputs(predicate) do
    html =
      render_component(&ArrayField.array_field/1, %{
        field: links_field(predicate),
        value: @items,
        root: @root,
        path: "doc[links]"
      })

    length(Regex.scan(~r/data-subfield-name="url"/, html))
  end

  test "a parent-scoped predicate shows url only in the item whose kind is url" do
    assert url_inputs(Map.put(@pred, "scope", "parent")) == 1
  end

  test "the default scope reads the document handed down as root" do
    assert url_inputs(@pred) == 0
    assert url_inputs(Map.put(@pred, "scope", "document")) == 0
  end
end
