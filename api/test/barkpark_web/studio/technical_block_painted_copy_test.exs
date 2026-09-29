defmodule BarkparkWeb.Studio.TechnicalBlockPaintedCopyTest do
  # task-bbfdcf4c80b8300d long tail: a footnote's painted notes edit where they
  # read. The preview keeps the reader HTML byte-for-byte and names, per painted
  # note, the panel field it writes (BarkparkPaperPaintedCopy hook).
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.TechnicalBlockEditor

  defp preview(block) do
    html =
      render_component(&TechnicalBlockEditor.technical_block_editor/1,
        block: block,
        id: block["id"]
      )

    {html,
     html
     |> LazyHTML.from_fragment()
     |> LazyHTML.query(~s([data-test-id="paper-technical-preview"]))}
  end

  test "a footnote preview wires each painted note to its panel field, reader HTML unchanged" do
    block = %{
      "id" => "fn",
      "type" => "footnote",
      "notes" => [
        %{"id" => "a", "text" => "First."},
        %{"id" => "b", "text" => ""},
        "legacy",
        %{"id" => "c", "text" => "Third."}
      ]
    }

    {html, el} = preview(block)
    assert html =~ Render.render_block(block, %{style: :article})
    assert LazyHTML.attribute(el, "phx-hook") == ["BarkparkPaperPaintedCopy"]
    assert LazyHTML.attribute(el, "id") == ["technical-preview-fn"]
    assert LazyHTML.attribute(el, "data-painted-copy-form") == ["technical-block-form-fn"]

    # Only the notes the reader paints (map, non-empty text) are named, in order,
    # so painted row i always writes the stored note it shows.
    assert LazyHTML.attribute(el, "data-painted-copy-names") == ["note-0-text,note-3-text"]
    assert el |> LazyHTML.query("li") |> Enum.count() == 2

    form = html |> LazyHTML.from_fragment() |> LazyHTML.query("form#technical-block-form-fn")

    for name <- ~w(note-0-text note-3-text) do
      assert form |> LazyHTML.query(~s(textarea[name="#{name}"])) |> Enum.count() == 1
    end
  end

  test "other technical types and a footnote with nothing painted get no wiring" do
    for block <- [
          %{"id" => "d", "type" => "diff", "diff" => "+x"},
          %{"id" => "t", "type" => "filetree", "text" => "a/"},
          %{"id" => "e", "type" => "footnote", "notes" => [%{"text" => ""}]},
          %{"id" => "m", "type" => "footnote", "notes" => "not a list"}
        ] do
      {_html, el} = preview(block)
      assert LazyHTML.attribute(el, "phx-hook") == [], "#{block["id"]} must not be wired"
    end
  end
end
