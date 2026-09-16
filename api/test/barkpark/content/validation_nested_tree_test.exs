defmodule Barkpark.Content.ValidationNestedTreeTest do
  @moduledoc """
  Gyldendal parity E1.11 — validation walks into composites and arrays and the
  Studio can find each finding at its SUBFIELD.

  `check/3` keeps its flat wire shape (`%{top_field => ["/path: msg"]}`, what
  the API's 422 `details` and the advisories carry). `check_tree/3` reads the
  SAME walk as a tree keyed by top-level field, then subfield name or row
  index, with `:__self__` for a node's own findings — the shape the composite
  and array components already index by.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Validation

  @seo_fields [
    %{"name" => "title", "title" => "Tittel", "type" => "string"},
    %{
      "name" => "description",
      "title" => "Beskrivelse",
      "type" => "text",
      "validation" => %{
        "max" => 300,
        "level" => "warning",
        "message" => "Beskrivelsen bør være under 300 tegn."
      }
    },
    %{
      "name" => "canonical",
      "title" => "Kanonisk URL",
      "type" => "string",
      "validation" => %{"pattern" => "^https://"}
    }
  ]

  # Twin-shaped: a `seo` composite (what a named object type inlines to) and a
  # `banners` arrayOf composite whose rows have a required `title`.
  @schema %{
    "name" => "frontpage",
    "fields" => [
      %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
      %{"name" => "seo", "title" => "SEO", "type" => "composite", "fields" => @seo_fields},
      %{
        "name" => "banners",
        "title" => "Toppbannere",
        "type" => "arrayOf",
        "validation" => %{"max" => 3, "message" => "Maks 3 kort tillatt."},
        "of" => %{
          "type" => "composite",
          "fields" => [
            %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
            %{
              "name" => "buttonHref",
              "type" => "string",
              "validation" => %{"pattern" => "^/", "message" => "Lenken må starte med /."}
            },
            %{
              "name" => "styling",
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "theme",
                  "type" => "string",
                  "validation" => %{"required" => true, "level" => "warning"}
                }
              ]
            }
          ]
        }
      }
    ]
  }

  @long String.duplicate("x", 301)

  describe "check_tree/3 — composite subfields" do
    test "a warning on a composite subfield lands under that subfield, and stays out of errors" do
      content = %{"seo" => %{"description" => @long, "canonical" => "https://x"}}

      %{errors: errors, warnings: warnings} = Validation.check_tree(content, "T", @schema)

      assert warnings == %{"seo" => %{"description" => ["Beskrivelsen bør være under 300 tegn."]}}
      assert errors == %{}
    end

    test "an error on a composite subfield lands under that subfield" do
      content = %{"seo" => %{"canonical" => "http://insecure"}}

      %{errors: errors} = Validation.check_tree(content, "T", @schema)

      assert errors["seo"] == %{"canonical" => ["Does not match required format"]}
    end

    test "the flat envelope of check/3 is unchanged: the same finding folded as a JSON-pointer" do
      content = %{"seo" => %{"description" => @long}}

      assert %{warnings: %{"seo" => ["/seo/description: Beskrivelsen bør være under 300 tegn."]}} =
               Validation.check(content, "T", @schema)

      assert {:ok, _} = Validation.validate(content, "T", @schema)
    end
  end

  describe "check_tree/3 — arrayOf rows" do
    test "a required miss in row 1 lands under that row's subfield, keyed by integer index" do
      content = %{
        "banners" => [
          %{"title" => "Fine", "styling" => %{"theme" => "a"}},
          %{"title" => "", "buttonHref" => "/ok", "styling" => %{"theme" => "a"}}
        ]
      }

      %{errors: errors, warnings: warnings} = Validation.check_tree(content, "T", @schema)

      assert errors["banners"] == %{1 => %{"title" => ["Required"]}}
      assert warnings == %{}

      # …and the flat shape carries the index in the path.
      assert %{errors: %{"banners" => ["/banners/1/title: Required"]}} =
               Validation.check(content, "T", @schema)
    end

    test "a warning two levels down (row → composite → leaf) lands at the leaf; the row's own error stays at the row" do
      content = %{"banners" => [%{"title" => "Fine", "buttonHref" => "nope", "styling" => %{}}]}

      %{errors: errors, warnings: warnings} = Validation.check_tree(content, "T", @schema)

      assert errors["banners"] == %{0 => %{"buttonHref" => ["Lenken må starte med /."]}}
      assert warnings["banners"] == %{0 => %{"styling" => %{"theme" => ["Required"]}}}
    end

    test "a finding on the array itself sits at :__self__ next to its rows" do
      rows = for i <- 1..4, do: %{"title" => "Kort #{i}", "styling" => %{"theme" => "a"}}
      content = %{"banners" => List.replace_at(rows, 3, %{"styling" => %{"theme" => "a"}})}

      %{errors: errors} = Validation.check_tree(content, "T", @schema)

      assert errors["banners"] == %{
               3 => %{"title" => ["Required"]},
               __self__: ["Maks 3 kort tillatt."]
             }
    end
  end

  describe "a stored %SchemaDefinition{} (what the Studio and the API door hold)" do
    test "is walked as v2, not rescued into flat mode" do
      struct = %Barkpark.Content.SchemaDefinition{name: "frontpage", fields: @schema["fields"]}
      content = %{"seo" => %{"description" => @long}, "banners" => [%{"styling" => %{}}]}

      %{errors: errors, warnings: warnings} = Validation.check_tree(content, "T", struct)
      assert errors["banners"] == %{0 => %{"title" => ["Required"]}}
      assert warnings["seo"] == %{"description" => ["Beskrivelsen bør være under 300 tegn."]}

      assert {:error, %{"banners" => ["/banners/0/title: Required"]}} =
               Validation.validate(content, "T", struct)
    end
  end

  describe "check_tree/3 — top level" do
    test "a top-level finding is a plain list, exactly as check/3 reports it" do
      %{errors: errors} = Validation.check_tree(%{}, nil, @schema)
      assert errors == %{"title" => ["Required"]}
    end

    test "a flat (legacy) schema answers the flat maps" do
      schema = %{
        "fields" => [
          %{"name" => "isbn", "type" => "string", "validation" => %{"pattern" => "^[0-9]{13}$"}}
        ]
      }

      assert %{errors: %{"isbn" => ["Does not match required format"]}, warnings: %{}} =
               Validation.check_tree(%{"isbn" => "x"}, nil, schema)
    end

    test "leaf_count/1 counts every finding in a tree" do
      content = %{
        "seo" => %{"description" => @long},
        "banners" => [%{"styling" => %{}}, %{"title" => "ok", "styling" => %{}}]
      }

      %{errors: errors, warnings: warnings} = Validation.check_tree(content, nil, @schema)
      # title (top) + banners/0/title
      assert Validation.leaf_count(errors) == 2
      # seo/description + two row themes
      assert Validation.leaf_count(warnings) == 3
    end
  end
end
