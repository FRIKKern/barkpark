defmodule Barkpark.Content.TitleDerivationTest do
  @moduledoc """
  Gyldendal parity E1.8 (task-b732cbaf366456e9, criteria 2–4) — a type with no
  `title` field fills the document title column from `list_preview.title`, so
  desk rows, `/v1/data/doc`, search hits and the reference pill all agree; a
  type WITH a title field is byte-identical to before.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.TitleDerivation
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "titleless-#{System.unique_integer([:positive])}"

  @author_fields [
    %{"name" => "name", "title" => "Navn", "type" => "string"},
    %{"name" => "slug", "title" => "Slug (URL)", "type" => "slug"},
    %{"name" => "bio", "title" => "Biografi", "type" => "text"}
  ]

  @author_schema %{
    "name" => "author",
    "title" => "Forfatter",
    "visibility" => "public",
    "fields" => @author_fields,
    "list_preview" => %{"title" => "name", "subtitle" => "slug"}
  }

  describe "derive/2 (pure)" do
    test "fills a blank title from the list_preview.title field" do
      attrs = %{"content" => %{"name" => "Sverre Graff", "slug" => "sverre-graff"}}
      assert TitleDerivation.derive(attrs, @author_schema)["title"] == "Sverre Graff"

      spec = put_in(@author_schema, ["list_preview", "title"], %{"field" => "name"})
      assert TitleDerivation.derive(attrs, spec)["title"] == "Sverre Graff"
    end

    test "a caller-supplied title always wins, and a schema WITH a title field is untouched" do
      attrs = %{"title" => "Hand-written", "content" => %{"name" => "Sverre Graff"}}
      assert TitleDerivation.derive(attrs, @author_schema) == attrs

      titled =
        Map.put(@author_schema, "fields", [
          %{"name" => "title", "type" => "string"} | @author_fields
        ])

      blank = %{"title" => "", "content" => %{"name" => "Sverre Graff"}}
      assert TitleDerivation.derive(blank, titled) == blank
    end

    test "no list_preview.title, a non-scalar value, an empty value, or a nil schema leave attrs alone" do
      attrs = %{"content" => %{"name" => "Sverre Graff"}}
      assert TitleDerivation.derive(attrs, Map.delete(@author_schema, "list_preview")) == attrs

      assert TitleDerivation.derive(%{"content" => %{"name" => %{"x" => 1}}}, @author_schema)[
               "title"
             ] == nil

      assert TitleDerivation.derive(%{"content" => %{"name" => "   "}}, @author_schema)["title"] ==
               nil

      assert TitleDerivation.derive(attrs, nil) == attrs
    end

    test "reads a SchemaDefinition-shaped struct (atom keys) as well as the raw map" do
      schema = %{fields: @author_fields, list_preview: %{"title" => "name"}}
      attrs = %{"content" => %{"name" => "Vilde Fastvold"}}
      assert TitleDerivation.derive(attrs, schema)["title"] == "Vilde Fastvold"

      assert TitleDerivation.preview_title(%{content: %{"name" => "Vilde Fastvold"}}, schema) ==
               "Vilde Fastvold"
    end
  end
end
