defmodule BarkparkWeb.Components.ScalarFieldStructuredValueTest do
  @moduledoc """
  A scalar Classic input handed a STRUCTURED stored value renders it read-only
  instead of crashing the editor, and posts nothing for it.

  Stranger walk (2026-09-30): a post created through the API with a
  Sanity-shaped slug (`{"_type": "slug", "current": "sanity-slug"}`) 500'd
  Studio — `Protocol.UndefinedError … Phoenix.HTML.Safe not implemented for
  Map` — because the slug input's `value` got the map. Any string/text/number/
  select/datetime field holding a map or list crashed the same way.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.Forms
  alias BarkparkWeb.Components.FieldInputs

  defp render(field, value) do
    render_component(&FieldInputs.input/1, %{
      field: field,
      editor_form: %{field["name"] => value}
    })
  end

  # A `slug` field is no longer in this list: `{current}` is its canonical
  # shape (owner ruling #43) and the slug input edits it as text (below).
  for {type, extra} <- [
        {"string", %{}},
        {"text", %{}},
        {"number", %{}},
        {"datetime", %{}},
        {"url", %{}},
        {"boolean", %{}},
        {"select", %{"options" => ["a", "b"]}}
      ] do
    @type_name type
    @extra extra
    test "#{type} with a map value renders read-only and posts no input" do
      field = Map.merge(%{"type" => @type_name, "name" => "f"}, @extra)
      html = render(field, %{"_type" => "slug", "current" => "sanity-slug"})

      assert html =~ ~s(data-readonly-field="f")
      assert html =~ "sanity-slug"
      refute html =~ ~s(name="doc[f]"), "a structured value must never be posted back as a string"
    end
  end

  test "a list value is caught the same way" do
    html = render(%{"type" => "string", "name" => "f"}, ["a", "b"])
    assert html =~ ~s(data-readonly-field="f")
    refute html =~ ~s(name="doc[f]")
  end

  test "a {current} slug is edited as its text (owner ruling #43)" do
    html =
      render(%{"type" => "slug", "name" => "f"}, %{"_type" => "slug", "current" => "sanity-slug"})

    assert html =~ ~s(name="doc[f]")
    assert html =~ ~s(value="sanity-slug")
    refute html =~ ~s(data-readonly-field="f")
  end

  test "scalar values keep their normal inputs" do
    assert render(%{"type" => "slug", "name" => "f"}, "plain-slug") =~ ~s(name="doc[f]")
    assert render(%{"type" => "string", "name" => "f"}, "x") =~ ~s(value="x")
  end

  test "doc_to_form hands a structured datetime through (the input layer renders it read-only)" do
    doc = %{title: "T", status: "draft", content: %{"when" => %{"start" => "2026-01-01"}}}
    schema = %{fields: [%{"name" => "when", "type" => "datetime"}]}
    assert Forms.doc_to_form(doc, schema)["when"] == %{"start" => "2026-01-01"}
  end
end
