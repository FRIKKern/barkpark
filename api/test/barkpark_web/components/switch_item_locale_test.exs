defmodule BarkparkWeb.Components.SwitchItemLocaleTest do
  @moduledoc """
  task-70fd7cef5d0266aa: in an nb-NO Studio every boolean switch read "On" /
  "Off" and an array row with no name read "Item" — Studio chrome left out of
  gettext. The switch words now read På / Av and the row Element; English is
  unchanged.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition.Field
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.StudioComponents.Controls

  defp nb(fun), do: Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fun)

  defp words(html) do
    for class <- ["form-switch-state-off", "form-switch-state-on"] do
      [_, word] = Regex.run(~r/<span class="#{class}">([^<]*)<\/span>/, html)
      word
    end
  end

  defp boolean_input do
    render_component(&FieldInputs.input/1, %{
      field: %{"type" => "boolean", "name" => "featured"},
      editor_form: %{}
    })
  end

  defp composite_switch do
    render_component(&CompositeField.composite_field/1, %{
      field: %Field{
        name: "choice",
        type: "composite",
        title: "Choice",
        raw: %{},
        fields: [%Field{name: "correct", type: "boolean", title: "Correct?", raw: %{}}]
      },
      value: %{"correct" => false}
    })
  end

  test "a boolean field's switch reads På / Av in nb-NO, On / Off in English" do
    assert nb(&boolean_input/0) |> words() == ["Av", "På"]
    assert boolean_input() |> words() == ["Off", "On"]
  end

  test "a composite's boolean subfield switch reads På / Av in nb-NO" do
    assert nb(&composite_switch/0) |> words() == ["Av", "På"]
    assert composite_switch() |> words() == ["Off", "On"]
  end

  test "bp_switch's default words follow the locale; passed labels win" do
    plain = fn -> render_component(&Controls.bp_switch/1, %{name: "s"}) end
    assert nb(plain) |> words() == ["Av", "På"]
    assert plain.() |> words() == ["Off", "On"]

    labelled =
      render_component(&Controls.bp_switch/1, %{name: "s", on_label: "Ja", off_label: "Nei"})

    assert words(labelled) == ["Nei", "Ja"]
  end

  test "an array row with no name or title is Element in nb-NO" do
    item = %{name: "choices[item]", fields: []}
    assert %{title: "Element"} = nb(fn -> ArrayField.item_preview(item, %{}) end)
    assert %{title: "Item"} = ArrayField.item_preview(item, %{})
  end
end
