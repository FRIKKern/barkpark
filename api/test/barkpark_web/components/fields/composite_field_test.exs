defmodule BarkparkWeb.Components.Fields.CompositeFieldTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.Fields.CompositeField
  alias Barkpark.Content.SchemaDefinition.Field

  describe "composite_field/1 — round-trip render" do
    test "renders fieldset with a label per sub-field and reflects values" do
      field = %Field{
        name: "address",
        type: "composite",
        title: "Address",
        fields: [
          %Field{name: "street", type: "string", title: "Street"},
          %Field{name: "city", type: "string", title: "City"}
        ]
      }

      html =
        render_component(&CompositeField.composite_field/1, %{
          field: field,
          value: %{"street" => "Karl Johans gate 1", "city" => "Oslo"},
          on_change: "form_change"
        })

      assert html =~ ~s(data-field-type="composite")
      assert html =~ ~s(data-field-name="address")
      assert html =~ "Address"
      assert html =~ "Street"
      assert html =~ "City"
      assert html =~ "Karl Johans gate 1"
      assert html =~ "Oslo"
      # phx-change wired through to leaves
      assert html =~ ~s(phx-change="form_change")
    end

    test "round-trips: rendered values match input value map keys" do
      field = %Field{
        name: "person",
        type: "composite",
        fields: [
          %Field{name: "given", type: "string"},
          %Field{name: "family", type: "string"}
        ]
      }

      input = %{"given" => "Frikk", "family" => "Bolla"}

      html =
        render_component(&CompositeField.composite_field/1, %{
          field: field,
          value: input
        })

      # Each sub-field's value attribute round-trips faithfully
      assert html =~ ~s(value="Frikk")
      assert html =~ ~s(value="Bolla")
    end

    test "renders inline error span per sub-field" do
      field = %Field{
        name: "person",
        type: "composite",
        fields: [
          %Field{name: "given", type: "string"},
          %Field{name: "family", type: "string"}
        ]
      }

      html =
        render_component(&CompositeField.composite_field/1, %{
          field: field,
          value: %{},
          errors: %{"given" => ["is required"]}
        })

      assert html =~ ~s(class="error")
      assert html =~ "is required"
      assert html =~ ~s(data-error-for="given")
    end

    test "title falls back to humanized name when title is absent" do
      field = %Field{
        name: "shipping_address",
        type: "composite",
        fields: [%Field{name: "street", type: "string"}]
      }

      html = render_component(&CompositeField.composite_field/1, %{field: field})
      assert html =~ "Shipping Address"
    end

    test "recurses into nested composite" do
      field = %Field{
        name: "outer",
        type: "composite",
        fields: [
          %Field{
            name: "inner",
            type: "composite",
            fields: [%Field{name: "leaf", type: "string"}]
          }
        ]
      }

      html =
        render_component(&CompositeField.composite_field/1, %{
          field: field,
          value: %{"inner" => %{"leaf" => "deeply nested"}}
        })

      assert html =~ "deeply nested"
    end
  end
end
