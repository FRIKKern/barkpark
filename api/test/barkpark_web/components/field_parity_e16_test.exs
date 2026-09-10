defmodule BarkparkWeb.Components.FieldParityE16Test do
  @moduledoc """
  Gyldendal parity E1.6 (task-cd8e10ca44ccb932, criteria 0–2) at the component
  layer — the same schema JSON the twin applies renders Sanity's affordances:

    * a reference that may point at SEVERAL types (`to: [{type}, …]` /
      `refTypes`) mounts ONE picker whose `ref-type` carries the set, at top
      level, as an array row, and inside a composite row;
    * an `arrayOf` of `image` mounts a media picker per row with the
      collapsed-row thumbnail;
    * a slug field's Generate button names its `options.source`.

  A single `refType` renders byte-identically to before.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Components.Fields.ArrayField

  defp render_input(assigns), do: render_component(&FieldInputs.input/1, assigns)

  defp parsed_field(raw) do
    {:ok, parsed} =
      SchemaDefinition.parse(%{"name" => "t", "title" => "T", "fields" => [raw]})

    hd(parsed.fields)
  end

  @five [
    %{"type" => "publication"},
    %{"type" => "article"},
    %{"type" => "category"},
    %{"type" => "series"},
    %{"type" => "page"}
  ]

  describe "reference_types/1" do
    test "reads refType, Sanity `to`, and refTypes — in order, deduplicated" do
      assert FieldInputs.reference_types(%{"refType" => "author"}) == ["author"]

      assert FieldInputs.reference_types(%{"to" => @five}) ==
               ~w(publication article category series page)

      assert FieldInputs.reference_types(%{"refTypes" => ["a", "b", "a"]}) == ["a", "b"]

      assert FieldInputs.reference_types(%{
               "refType" => "a",
               "to" => [%{"type" => "a"}, %{"type" => "b"}]
             }) ==
               ["a", "b"]

      assert FieldInputs.reference_types(%{"type" => "reference"}) == []
    end
  end

  describe "top-level reference" do
    test "a single refType renders the picker exactly as before" do
      html =
        render_input(%{
          field: %{"type" => "reference", "name" => "author", "refType" => "author"},
          editor_form: %{"author" => "a-1"},
          dataset: "production",
          scope_prefix: "/w/acme/p/blog"
        })

      assert html =~ ~s(<bp-reference-picker)
      assert html =~ ~s(ref-type="author")
      assert html =~ ~s(value="a-1")
      assert html =~ ~s(name="doc[author]")
    end

    test "Sanity `to: [...]` renders ONE picker carrying every type comma-joined" do
      html =
        render_input(%{
          field: %{"type" => "reference", "name" => "linkedDocument", "to" => @five},
          editor_form: %{},
          dataset: "production"
        })

      assert html =~ ~s(<bp-reference-picker)
      assert html =~ ~s(ref-type="publication,article,category,series,page")
      refute html =~ ~r{<input[^>]*type="text"[^>]*doc\[linkedDocument\]}
    end
  end

  describe "arrayOf reference rows" do
    test "a multi-type element mounts a picker per row with the joined set" do
      html =
        render_component(&ArrayField.array_field/1,
          field:
            parsed_field(%{
              "name" => "links",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "to" => @five}
            }),
          value: ["pub-1", "article-2"],
          path: "doc[links]",
          dataset: "production",
          scope_prefix: "/w/acme/p/blog"
        )

      assert length(Regex.scan(~r/<bp-reference-picker/, html)) == 2
      assert html =~ ~s(ref-type="publication,article,category,series,page")
      assert html =~ ~s(scope-prefix="/w/acme/p/blog")
      assert html =~ ~s(name="doc[links][0]")
    end
  end

  describe "composite reference subfield" do
    test "renders the picker (not a text input) bridged into the row's own input name" do
      field =
        parsed_field(%{
          "name" => "banners",
          "type" => "arrayOf",
          "of" => %{
            "type" => "composite",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "linkedDocument", "type" => "reference", "to" => @five}
            ]
          }
        })

      html =
        render_component(&ArrayField.array_field/1,
          field: field,
          value: [%{"title" => "Crime", "linkedDocument" => "pub-1"}],
          path: "doc[banners]",
          dataset: "production",
          scope_prefix: "/w/acme/p/blog"
        )

      assert html =~ ~s(<bp-reference-picker)
      assert html =~ ~s(ref-type="publication,article,category,series,page")
      assert html =~ ~s(scope-prefix="/w/acme/p/blog")
      assert html =~ ~s(name="doc[banners][0].linkedDocument")
      assert html =~ ~s(value="pub-1")
      refute html =~ ~r{<input[^>]*type="text"[^>]*doc\[banners\]\[0\]\.linkedDocument}
    end

    test "a composite reference WITHOUT any declared type keeps the plain text input" do
      field =
        parsed_field(%{
          "name" => "rows",
          "type" => "arrayOf",
          "of" => %{
            "type" => "composite",
            "fields" => [%{"name" => "ref", "type" => "reference"}]
          }
        })

      html =
        render_component(&ArrayField.array_field/1,
          field: field,
          value: [%{"ref" => "x"}],
          path: "doc[rows]"
        )

      refute html =~ "<bp-reference-picker"
      assert html =~ ~r{<input[^>]*type="text"[^>]*doc\[rows\]\[0\]\.ref}
    end
  end

  describe "arrayOf image rows" do
    @img %{
      "assetId" => "asset-1",
      "url" => "https://cdn.example/2026/09/cover-abc.jpg",
      "alt" => "Omslag",
      "width" => 1200,
      "height" => 800
    }

    test "each row mounts a media picker with the declared hotspot/alt and the row thumbnail" do
      html =
        render_component(&ArrayField.array_field/1,
          field:
            parsed_field(%{
              "name" => "images",
              "title" => "Fremhevete bilder",
              "type" => "arrayOf",
              "of" => %{"type" => "image", "options" => %{"hotspot" => true, "alt" => true}}
            }),
          value: [@img, ""],
          path: "doc[images]",
          dataset: "production",
          scope_prefix: "/w/acme/p/blog",
          api_token_raw: "tok-123"
        )

      assert length(Regex.scan(~r/<bp-media-picker/, html)) == 2
      assert html =~ ~s(hotspot)
      assert html =~ ~s(data-token="tok-123")
      assert html =~ ~s(scope-prefix="/w/acme/p/blog")
      assert html =~ ~s(name="doc[images][0]")
      assert html =~ ~s(name="doc[images][1]")
      # the stored object rides the hidden input as its JSON string
      assert html =~ ~s(value="{&quot;alt&quot;:&quot;Omslag&quot;)
      # collapsed row: thumbnail from the url, title from the alt text
      assert html =~ ~s(<img src="https://cdn.example/2026/09/cover-abc.jpg")
      assert html =~ ~s(<span class="bp-array-item-title">Omslag</span>)
      # the empty second row is open (nothing to preview yet)
      assert html =~ ~r{<details class="bp-array-item"[^>]*open}
      refute html =~ ~r{<input[^>]*type="text"[^>]*doc\[images\]}
    end
  end

  describe "slug source" do
    test "Generate names the declared options.source, defaulting to title" do
      html =
        render_input(%{
          field: %{"type" => "slug", "name" => "slug", "options" => %{"source" => "name"}},
          editor_form: %{}
        })

      assert html =~ ~s(data-slug-source="name")
      assert html =~ ~s(title="Generate from name")

      html = render_input(%{field: %{"type" => "slug", "name" => "slug"}, editor_form: %{}})
      assert html =~ ~s(data-slug-source="title")
    end

    test "slug_source/2 finds the field on a schema" do
      schema = %{
        fields: [
          %{"name" => "name", "type" => "string"},
          %{"name" => "slug", "type" => "slug", "options" => %{"source" => "name"}}
        ]
      }

      assert FieldInputs.slug_source(schema, "slug") == "name"
      assert FieldInputs.slug_source(schema, "other") == "title"
      assert FieldInputs.slug_source(nil, "slug") == "title"
    end
  end
end
