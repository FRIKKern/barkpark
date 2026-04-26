defmodule BarkparkWeb.Studio.Plugins.FieldComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition.Field
  alias BarkparkWeb.Studio.Plugins.FieldComponents

  describe "composite/1" do
    test "renders fieldset with sub-field labels and values" do
      field = %Field{
        name: "address",
        type: "composite",
        title: "Address",
        fields: [
          %Field{name: "city", type: "string", title: "City"}
        ]
      }

      html =
        render_component(&FieldComponents.composite/1, %{
          field: field,
          value: %{"city" => "Bergen"}
        })

      assert html =~ "Address"
      assert html =~ "City"
      assert html =~ "Bergen"
      assert html =~ ~s(data-field-type="composite")
    end
  end

  describe "array_of/1" do
    test "renders ordered array with up/down buttons" do
      field = %Field{
        name: "items",
        type: "arrayOf",
        ordered: true,
        of: %Field{name: "item", type: "string"}
      }

      html =
        render_component(&FieldComponents.array_of/1, %{
          field: field,
          value: ["a", "b"]
        })

      assert html =~ ~s(data-field-type="arrayOf")
      assert html =~ ~s(data-ordered="true")
      assert html =~ "Move up"
      assert html =~ "Move down"
      assert html =~ "+ Add"
    end

    test "unordered array hides up/down buttons" do
      field = %Field{
        name: "tags",
        type: "arrayOf",
        ordered: false,
        of: %Field{name: "tag", type: "string"}
      }

      html =
        render_component(&FieldComponents.array_of/1, %{
          field: field,
          value: []
        })

      refute html =~ "Move up"
      refute html =~ "Move down"
      assert html =~ "+ Add"
    end
  end

  describe "codelist/1" do
    test "renders empty-registry placeholder when registry returns nothing" do
      field = %Field{
        name: "role",
        type: "codelist",
        codelist_id: "ghostplugin:never_registered",
        version: 1
      }

      # Pass an explicit loader that always returns nil — we don't depend on
      # the database in this unit test (matches the WI3-not-yet-seeded case).
      html =
        render_component(&FieldComponents.codelist/1, %{
          field: field,
          value: nil,
          codelist_loader: fn _, _ -> nil end
        })

      assert html =~ "no codelist registered"
      assert html =~ "ghostplugin:never_registered"
      assert html =~ "disabled"
    end

    test "renders populated select with leaf options when loader returns values" do
      field = %Field{
        name: "role",
        type: "codelist",
        codelist_id: "onixedit:contributor_role",
        version: 73
      }

      # Stubbed codelist that mirrors the persisted shape used by Phase 0.
      codelist = %{
        values: [
          %{
            id: 1,
            code: "A01",
            position: 0,
            parent_id: nil,
            translations: [%{language: "eng", label: "By (author)"}]
          },
          %{
            id: 2,
            code: "A02",
            position: 1,
            parent_id: nil,
            translations: [%{language: "eng", label: "With"}]
          }
        ]
      }

      html =
        render_component(&FieldComponents.codelist/1, %{
          field: field,
          value: "A01",
          plugin_name: "onixedit",
          codelist_loader: fn "onixedit", "onixedit:contributor_role" -> codelist end
        })

      refute html =~ "no codelist registered"
      assert html =~ "A01"
      assert html =~ "By (author)"
      assert html =~ "A02"
      assert html =~ "With"
    end
  end

  describe "localized_text/1" do
    test "renders one input per language declared on the field" do
      field = %Field{
        name: "blurb",
        type: "localizedText",
        languages: ["eng", "nob"],
        format: :plain,
        fallback_chain: ["eng"]
      }

      html =
        render_component(&FieldComponents.localized_text/1, %{
          field: field,
          value: %{"eng" => "Hi", "nob" => "Hei"}
        })

      assert html =~ "Hi"
      assert html =~ "Hei"
      assert html =~ "eng"
      assert html =~ "nob"
    end

    test "rich format adds a marker class for Phase 5+ enhancements" do
      field = %Field{
        name: "body",
        type: "localizedText",
        languages: ["eng"],
        format: :rich,
        fallback_chain: []
      }

      html =
        render_component(&FieldComponents.localized_text/1, %{
          field: field,
          value: %{}
        })

      assert html =~ "bp-localized-rich"
    end
  end
end
