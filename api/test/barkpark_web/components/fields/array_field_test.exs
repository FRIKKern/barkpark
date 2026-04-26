defmodule BarkparkWeb.Components.Fields.ArrayFieldTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.Fields.ArrayField
  alias Barkpark.Content.SchemaDefinition.Field

  describe "array up/down persistence" do
    test "move_up at index 2 in a 3-element list yields [a, c, b]" do
      assert ["a", "c", "b"] = ArrayField.move_up(["a", "b", "c"], 2)
    end

    test "chained move_up then move_down — sequence persists faithfully" do
      list = ["a", "b", "c"]
      after_up = ArrayField.move_up(list, 2)
      assert ["a", "c", "b"] = after_up

      after_down = ArrayField.move_down(after_up, 0)
      assert ["c", "a", "b"] = after_down
    end

    test "move_up at index 0 is a no-op" do
      assert ["a", "b", "c"] = ArrayField.move_up(["a", "b", "c"], 0)
    end

    test "move_down at last index is a no-op" do
      assert ["a", "b", "c"] = ArrayField.move_down(["a", "b", "c"], 2)
    end

    test "move_up out of range is a no-op" do
      assert ["a"] = ArrayField.move_up(["a"], 5)
    end

    test "add_row appends" do
      assert ["a", "b", "c"] = ArrayField.add_row(["a", "b"], "c")
    end

    test "remove_row drops the indexed element" do
      assert ["a", "c"] = ArrayField.remove_row(["a", "b", "c"], 1)
    end
  end

  describe "array_field/1 — render" do
    test "ordered:true renders up/down buttons with phx-click events" do
      field = %Field{
        name: "tags",
        type: "arrayOf",
        ordered: true,
        of: %Field{name: "tag", type: "string"}
      }

      html =
        render_component(&ArrayField.array_field/1, %{
          field: field,
          value: ["alpha", "beta", "gamma"],
          on_reorder: "array_op"
        })

      assert html =~ ~s(data-ordered="true")
      assert html =~ ~s(phx-click="array_op")
      assert html =~ ~s(phx-value-action="move_up")
      assert html =~ ~s(phx-value-action="move_down")
      assert html =~ ~s(phx-value-action="remove_row")
      assert html =~ ~s(phx-value-action="add_row")
      # First row's up button is disabled
      assert html =~
               ~r/phx-value-action="move_up"[^>]*phx-value-field="tags"[^>]*phx-value-index="0"[^>]*disabled/

      # Last row's down button is disabled
      assert html =~ ~r/phx-value-action="move_down"[^>]*phx-value-index="2"[^>]*disabled/
    end

    test "ordered:false hides up/down buttons" do
      field = %Field{
        name: "tags",
        type: "arrayOf",
        ordered: false,
        of: %Field{name: "tag", type: "string"}
      }

      html =
        render_component(&ArrayField.array_field/1, %{
          field: field,
          value: ["alpha", "beta"]
        })

      refute html =~ ~s(phx-value-action="move_up")
      refute html =~ ~s(phx-value-action="move_down")
      # Add and remove are still present
      assert html =~ ~s(phx-value-action="add_row")
      assert html =~ ~s(phx-value-action="remove_row")
    end

    test "renders inline row error" do
      field = %Field{
        name: "tags",
        type: "arrayOf",
        ordered: true,
        of: %Field{name: "tag", type: "string"}
      }

      html =
        render_component(&ArrayField.array_field/1, %{
          field: field,
          value: ["alpha"],
          errors: %{0 => ["too short"]}
        })

      assert html =~ "too short"
      assert html =~ ~s(data-error-for-row="0")
    end

    test "no-drag: emits no JS hook attribute" do
      # Decision 13 — no Sortable.js, no `phx-hook`. Pure server round-trip.
      field = %Field{
        name: "tags",
        type: "arrayOf",
        ordered: true,
        of: %Field{name: "tag", type: "string"}
      }

      html =
        render_component(&ArrayField.array_field/1, %{
          field: field,
          value: ["alpha", "beta"]
        })

      refute html =~ "phx-hook"
      refute html =~ "Sortable"
    end
  end
end
