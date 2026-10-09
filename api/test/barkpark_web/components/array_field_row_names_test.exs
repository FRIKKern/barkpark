defmodule BarkparkWeb.Components.ArrayFieldRowNamesTest do
  @moduledoc """
  task-0497a3e7f8d7eeb7: an arrayOf field's row inputs had no name of their
  own — the fieldset legend names the group, not each input — so a screen
  reader announced every row as just "edit text". Each row now carries
  "<field> <n>", reference rows hand it to their picker, and the checklist
  counter beside the legend reads in the Studio language.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Components.Fields.ArrayField

  defp parsed_field(title, of) do
    {:ok, parsed} =
      SchemaDefinition.parse(%{
        "name" => "t",
        "title" => "T",
        "fields" => [
          %{
            "name" => "rows",
            "title" => title,
            "type" => "arrayOf",
            "ordered" => true,
            "of" => of
          }
        ]
      })

    hd(parsed.fields)
  end

  defp render(field, value, locale) do
    Gettext.with_locale(BarkparkWeb.Gettext, locale, fn ->
      render_component(&ArrayField.array_field/1,
        field: field,
        value: value,
        path: "doc[rows]",
        dataset: "production"
      )
    end)
  end

  test "each text row is named after the field and its position" do
    html = render(parsed_field("Stikkord", %{"type" => "string"}), ["dikt", "fjell"], "en")

    assert html =~ ~r/<input[^>]*name="doc\[rows\]\[0\]"[^>]*aria-label="Stikkord 1"/s
    assert html =~ ~r/<input[^>]*name="doc\[rows\]\[1\]"[^>]*aria-label="Stikkord 2"/s
  end

  test "a reference row hands its picker the row's name" do
    field = parsed_field("Bidragsytere", %{"type" => "reference", "refType" => "author"})
    html = render(field, ["author-a"], "en")

    assert html =~ ~r/<bp-reference-picker[^>]*data-field-label="Bidragsytere 1"/s
  end

  test "the checklist counter reads in the Studio language" do
    field =
      parsed_field("Criteria", %{
        "type" => "composite",
        "fields" => [
          %{"name" => "criterion", "type" => "string"},
          %{"name" => "met", "type" => "boolean"}
        ]
      })

    value = [%{"criterion" => "a", "met" => true}, %{"criterion" => "b", "met" => false}]

    assert render(field, value, "nb_NO") =~ "1/2 oppfylt"
    assert render(field, value, "en") =~ "1/2 met"
  end
end
