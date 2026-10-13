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

  # Owner ruling #44: Portable Text is the canonical value, so the editor
  # opens it as HTML and the save turns the HTML back into blocks.
  test "a Portable Text value opens in the rich-text editor as HTML" do
    html = render_rt(@blocks)

    assert html =~ "<bp-rich-text-editor"
    assert html =~ ~s(name="doc[content]")
    assert html =~ "&lt;p&gt;Hello blocks&lt;/p&gt;"
    refute html =~ ~s(data-readonly-field="content")
  end

  test "a list that is not Portable Text still renders read-only" do
    html = render_rt([%{"type" => "paragraph", "text" => "x"}])
    assert html =~ ~s(data-readonly-field="content")
    refute html =~ ~s(name="doc[content]")
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
