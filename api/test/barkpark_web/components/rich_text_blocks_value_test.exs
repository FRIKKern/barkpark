defmodule BarkparkWeb.Components.RichTextBlocksValueTest do
  @moduledoc """
  A plain richText field whose stored value is block content (a list), not an
  HTML string, renders read-only instead of crashing the editor.

  Stranger walk (2026-09-30): `bp make schema widget` → `bp schema apply` →
  `bp seed widget` stores `content` (richText) as Portable Text blocks; opening
  the document in Studio answered a 500 — `ArgumentError … lists in
  Phoenix.HTML and templates may only contain integers …` — because the
  HTML-string editor's `value` attribute got the list.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.FieldInputs

  @blocks [
    %{
      "_type" => "block",
      "_key" => "seedblk1",
      "style" => "normal",
      "markDefs" => [],
      "children" => [
        %{"_type" => "span", "_key" => "s1", "text" => "Hello blocks", "marks" => []}
      ]
    }
  ]

  defp render_rt(value) do
    render_component(&FieldInputs.input/1, %{
      field: %{"type" => "richText", "name" => "content"},
      editor_form: %{"content" => value}
    })
  end

  test "a block-list value renders read-only, with NO form input (a save preserves it)" do
    html = render_rt(@blocks)

    assert html =~ ~s(data-readonly-field="content")
    assert html =~ "Hello blocks"
    assert html =~ "read-only"
    refute html =~ ~s(name="doc[content]"), "no input may submit a string over the stored blocks"
    refute html =~ "<bp-rich-text-editor"
  end

  test "an HTML string still gets the rich-text editor, unchanged" do
    html = render_rt("<p>Hi</p>")

    assert html =~ "<bp-rich-text-editor"
    assert html =~ ~s(name="doc[content]")
  end

  test "an absent value gets the editor, empty" do
    html =
      render_component(&FieldInputs.input/1, %{
        field: %{"type" => "richText", "name" => "content"},
        editor_form: %{}
      })

    assert html =~ "<bp-rich-text-editor"
  end
end
