defmodule BarkparkWeb.Components.ReferenceObjectValueTest do
  @moduledoc """
  A reference stored Sanity-style — `{"_ref": id, "_type": "reference"}`, the
  shape the API accepts and `?expand` resolves (api-v1.md) — renders its id in
  every Studio reference picker instead of crashing the editor.

  Stranger walk (2026-09-30): `bp doc patch article a2 --set
  'author:={"_ref":"ada","_type":"reference"}'`, then opening a2 in Studio,
  answered a 500 — `Protocol.UndefinedError … Phoenix.HTML.Safe not
  implemented for Map` — because the picker's `value` attribute got the map.
  The arrayOf row and composite subfield pickers `to_string/1`-ed the value and
  would raise the same way.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Components.Fields.ArrayField

  @ref %{"_ref" => "ada", "_type" => "reference"}

  defp parsed_field(raw) do
    {:ok, parsed} = SchemaDefinition.parse(%{"name" => "t", "title" => "T", "fields" => [raw]})
    hd(parsed.fields)
  end

  test "reference_id/1 reads a bare id, a string- or atom-keyed _ref, and nothing else" do
    assert FieldInputs.reference_id("ada") == "ada"
    assert FieldInputs.reference_id(@ref) == "ada"
    assert FieldInputs.reference_id(%{_ref: "ada"}) == "ada"
    assert FieldInputs.reference_id(nil) == ""
    assert FieldInputs.reference_id(%{"title" => "x"}) == ""
  end

  test "a top-level reference field shows the object's id" do
    html =
      render_component(&FieldInputs.input/1, %{
        field: %{"type" => "reference", "name" => "author", "to" => [%{"type" => "person"}]},
        editor_form: %{"author" => @ref}
      })

    assert html =~ ~r{<input type="hidden"[^>]*id="bp-ref-hidden-author"[^>]*value="ada"}
    assert html =~ ~r{<bp-reference-picker[^>]*value="ada"}
  end

  test "a mediaAsset reference field shows the object's id" do
    html =
      render_component(&FieldInputs.input/1, %{
        field: %{"type" => "reference", "name" => "cover", "refType" => "mediaAsset"},
        editor_form: %{"cover" => %{"_ref" => "asset-1", "_type" => "reference"}},
        dataset: "production",
        scope_prefix: "",
        api_token_raw: ""
      })

    assert html =~ ~r{<bp-media-picker[^>]*value="asset-1"}
  end

  test "an arrayOf reference row shows the object's id" do
    html =
      render_component(&ArrayField.array_field/1,
        field:
          parsed_field(%{
            "name" => "people",
            "type" => "arrayOf",
            "of" => %{"type" => "reference", "refType" => "person"}
          }),
        value: [@ref],
        path: "doc[people]",
        dataset: "production"
      )

    assert html =~ ~r{<bp-reference-picker[^>]*value="ada"}
  end

  test "a composite reference subfield shows the object's id" do
    html =
      render_component(&ArrayField.array_field/1,
        field:
          parsed_field(%{
            "name" => "credits",
            "type" => "arrayOf",
            "of" => %{
              "type" => "composite",
              "fields" => [
                %{"name" => "role", "type" => "string"},
                %{"name" => "who", "type" => "reference", "to" => [%{"type" => "person"}]}
              ]
            }
          }),
        value: [%{"role" => "author", "who" => @ref}],
        path: "doc[credits]",
        dataset: "production"
      )

    assert html =~ ~r{<bp-reference-picker[^>]*value="ada"}
  end
end
