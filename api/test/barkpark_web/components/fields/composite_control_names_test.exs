defmodule BarkparkWeb.Components.Fields.CompositeControlNamesTest do
  @moduledoc """
  Every control an author can reach in an object field has an accessible name
  (axe `label`). A datetime subfield renders a hidden input that carries the
  value and a local picker the author types into; the subfield's
  `<label for>` names the HIDDEN one, so the picker read as an unnamed
  "date and time" box. Found on the OnixEdit book form, where Contributors
  and Status hold 7 of them; every object field with a datetime has it.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.Fields.CompositeField
  alias Barkpark.Content.SchemaDefinition.Field

  @leaf_types ~w(string text number datetime date url email boolean)

  test "every visible subfield control is named, whatever its type" do
    field = %Field{
      name: "status",
      type: "composite",
      title: "Status",
      fields: for(t <- @leaf_types, do: %Field{name: "f_#{t}", type: t, title: "Title #{t}"})
    }

    doc =
      render_component(&CompositeField.composite_field/1, %{field: field, value: %{}})
      |> LazyHTML.from_fragment()

    labelled =
      for el <- LazyHTML.query(doc, "label[for]"), into: MapSet.new(), do: attr(el, "for")

    controls =
      doc
      |> LazyHTML.query("input:not([type=hidden]), select, textarea")
      |> Enum.to_list()

    assert length(controls) >= length(@leaf_types)

    unnamed =
      for el <- controls,
          not (MapSet.member?(labelled, attr(el, "id")) or present?(attr(el, "aria-label")) or
                 present?(attr(el, "aria-labelledby"))),
          do: LazyHTML.to_html(el)

    assert unnamed == [], "controls with no accessible name: #{inspect(unnamed)}"
  end

  test "the datetime picker carries the subfield's own title" do
    field = %Field{
      name: "status",
      type: "composite",
      fields: [
        %Field{name: "submitted_at", type: "datetime"},
        %Field{name: "staged_at", type: "datetime", title: "Staged"}
      ]
    }

    html = render_component(&CompositeField.composite_field/1, %{field: field, value: %{}})

    assert html =~ ~r/<input type="datetime-local"[^>]*aria-label="Submitted At"/
    assert html =~ ~r/<input type="datetime-local"[^>]*aria-label="Staged"/
  end

  defp attr(el, name) do
    case LazyHTML.attribute(el, name) do
      [v | _] -> v
      [] -> nil
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
