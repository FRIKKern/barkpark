defmodule BarkparkWeb.Components.NamedTypeRenderParityTest do
  @moduledoc """
  Gyldendal parity E3.6: a named object type resolves to a plain composite, so
  the editor renders it byte-identically to the same fields declared inline —
  tabs (groups), descriptions, image picker, everything the composite renderer
  does. The only difference in the resolved map is the `namedType` stamp, which
  the renderer ignores.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Components.Fields.CompositeField

  @seo_fields [
    %{
      "name" => "title",
      "title" => "Tittel",
      "type" => "string",
      "description" => "Tittelen i søkeresultater.",
      "group" => "text"
    },
    %{"name" => "description", "title" => "Beskrivelse", "type" => "text", "group" => "text"},
    %{
      "name" => "image",
      "title" => "Bilde",
      "type" => "image",
      "options" => %{"hotspot" => true, "alt" => true},
      "group" => "media"
    },
    %{
      "name" => "noindex",
      "title" => "Skru av indeksering?",
      "type" => "boolean",
      "group" => "text"
    }
  ]
  @groups [
    %{"name" => "text", "title" => "Tekst", "default" => true},
    %{"name" => "media", "title" => "Bilde"}
  ]

  defp base(extra) do
    Map.merge(
      %{
        "name" => "seo",
        "title" => "SEO og sosiale medier",
        "description" => "Overstyr for deling.",
        "type" => "composite",
        "fields" => @seo_fields,
        "groups" => @groups
      },
      extra
    )
  end

  # The same parse the Studio runs on a stored schema (SchemaDefinition.parse/2)
  # turns the raw field map into the %Field{} the composite renderer takes.
  defp render_field(raw) do
    {:ok, parsed} = SchemaDefinition.parse(%{"name" => "x", "title" => "X", "fields" => [raw]})
    [field] = parsed.fields

    render_component(&CompositeField.composite_field/1, %{
      field: field,
      value: %{"title" => "Snow Angels", "noindex" => true},
      dataset: "production",
      scope_prefix: "/w/twin/p/default"
    })
  end

  test "the resolved named type renders byte-identically to the inline composite" do
    inline = render_field(base(%{}))
    named = render_field(base(%{"namedType" => "seo"}))

    assert inline == named
    assert inline =~ "Tittelen i søkeresultater."
    assert inline =~ "bp-media-picker"
    assert inline =~ "Tekst"
  end
end
