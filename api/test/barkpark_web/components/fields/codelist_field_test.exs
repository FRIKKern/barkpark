defmodule BarkparkWeb.Components.Fields.CodelistFieldTest do
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.Fields.CodelistField
  alias Barkpark.Content.Codelists
  alias Barkpark.Content.SchemaDefinition.Field

  describe "empty registry" do
    test "renders the 'no codelist registered' placeholder when no codelist is registered" do
      field = %Field{
        name: "role",
        type: "codelist",
        codelist_id: "ghost:does_not_exist",
        version: 73
      }

      html =
        render_component(&CodelistField.codelist_field/1, %{
          field: field,
          value: nil
        })

      assert html =~ "no codelist registered"
      assert html =~ "ghost:does_not_exist"
      assert html =~ ~s(data-codelist-empty="true")
      assert html =~ "disabled"
    end

    test "renders placeholder when the codelist row exists but has zero values" do
      {:ok, _} =
        Codelists.register("emptyplugin", "emptyplugin:dead_list", %{
          issue: "1",
          values: []
        })

      field = %Field{
        name: "role",
        type: "codelist",
        codelist_id: "emptyplugin:dead_list",
        version: 1
      }

      html =
        render_component(&CodelistField.codelist_field/1, %{
          field: field,
          value: nil,
          plugin_name: "emptyplugin"
        })

      assert html =~ "no codelist registered"
    end

    test "exposes the literal phrase as a public function for cross-test consistency" do
      assert CodelistField.empty_registry_phrase() == "no codelist registered"
    end
  end

  describe "populated registry" do
    setup do
      {:ok, _} =
        Codelists.register("onixedit", "onixedit:contributor_role", %{
          issue: "73",
          values: [
            %{
              code: "A01",
              position: 0,
              translations: [
                %{language: "eng", label: "By (author)"},
                %{language: "nob", label: "Av (forfatter)"}
              ]
            },
            %{
              code: "A02",
              position: 1,
              translations: [%{language: "eng", label: "With"}]
            },
            %{
              code: "B01",
              position: 2,
              translations: [%{language: "eng", label: "Edited by"}]
            }
          ]
        })

      :ok
    end

    test "renders one option per registered code with its label" do
      field = %Field{
        name: "role",
        type: "codelist",
        codelist_id: "onixedit:contributor_role",
        version: 73
      }

      html =
        render_component(&CodelistField.codelist_field/1, %{
          field: field,
          value: "A01",
          plugin_name: "onixedit"
        })

      # Codes appear
      assert html =~ "A01"
      assert html =~ "A02"
      assert html =~ "B01"
      # Labels appear (default fallback prefers nob → "Av (forfatter)" wins for A01)
      assert html =~ "Av (forfatter)"
      assert html =~ "With"
      assert html =~ "Edited by"
      # Selected option reflects the current value (selected attr may render as
      # bare `selected` or `selected="selected"` depending on HEEx renderer)
      assert html =~ ~r/value="A01"\s+selected/
      # Codelist version is exposed in a data attr
      assert html =~ ~s(data-codelist-version="73")
      # Empty placeholder is NOT rendered
      refute html =~ "no codelist registered"
    end

    test "phx-change wires through to the select element" do
      field = %Field{
        name: "role",
        type: "codelist",
        codelist_id: "onixedit:contributor_role"
      }

      html =
        render_component(&CodelistField.codelist_field/1, %{
          field: field,
          value: nil,
          plugin_name: "onixedit",
          on_change: "form_change"
        })

      assert html =~ ~s(phx-change="form_change")
    end
  end

  describe "no blocking script in head (golden rule #4)" do
    test "component emits no <script> tag at all" do
      field = %Field{
        name: "role",
        type: "codelist",
        codelist_id: "ghost:does_not_exist"
      }

      html =
        render_component(&CodelistField.codelist_field/1, %{
          field: field,
          value: nil
        })

      refute html =~ "<script"
    end
  end
end
