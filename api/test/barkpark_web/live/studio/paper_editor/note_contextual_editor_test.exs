defmodule BarkparkWeb.Studio.PaperEditor.NoteContextualEditorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "note menu keeps the first three options" do
    html = render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: [])

    options =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("select[name='block-type'] option")
      |> LazyHTML.attribute("value")

    assert Enum.take(options, 3) == ["paragraph", "heading", "list"]
    assert "note" in options
  end

  test "raw reader preview and closed accessible controls share the authoring pipeline" do
    block = %{
      "id" => "n",
      "type" => "note",
      "label" => "Review",
      "lead" => "First",
      "text" => "Body"
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1, block: block, canvas_enabled: false)

    tree = LazyHTML.from_fragment(html)
    assert html =~ Render.render_block(block, %{style: :article})
    refute Enum.empty?(LazyHTML.query(tree, "#note-controls-n:not([open])"))

    assert LazyHTML.attribute(LazyHTML.query(tree, "#note-form-n"), "phx-change") == [
             "paper-block-autosave"
           ]

    assert LazyHTML.attribute(LazyHTML.query(tree, "#note-form-n"), "phx-submit") == [
             "paper-edit-block"
           ]

    for {field, label, value} <- [
          {"label", "Label", "Review"},
          {"lead", "Lead (optional)", "First"},
          {"body", "Body", "Body"}
        ] do
      assert LazyHTML.text(LazyHTML.query(tree, "label[for='note-#{field}-n']")) == label

      assert LazyHTML.text(LazyHTML.query(tree, "textarea#note-#{field}-n[name='note-#{field}']")) ==
               value
    end
  end

  test "unsafe carriers keep the canonical preview and a closed read-only disclosure" do
    for extra <- [
          %{
            "content" => [
              %{"type" => "text", "value" => "One"},
              %{"type" => "text", "value" => "Two"}
            ]
          },
          %{"text" => "Primary", "content" => [%{"type" => "text", "value" => "Hidden"}]},
          %{"slots" => %{"body" => [%{"type" => "paragraph", "content" => "Opaque"}]}},
          %{
            "vendor" => %{"note" => [1, 2]},
            "slots" => %{
              "unknown" => %{"opaque" => true},
              "body" => [
                %{
                  "id" => "body",
                  "type" => "paragraph",
                  "vendor" => %{"paragraph" => [3]},
                  "content" => [
                    %{"type" => "text", "value" => "First run", "vendor" => %{"leaf" => 1}},
                    %{"type" => "code", "value" => "Second run", "vendor" => %{"leaf" => 2}}
                  ]
                }
              ]
            }
          }
        ] do
      block = Map.merge(%{"id" => "n", "type" => "note", "label" => "Review"}, extra)

      html =
        render_component(&PaperEditor.paper_block_fields/1, block: block, canvas_enabled: false)

      tree = LazyHTML.from_fragment(html)
      assert html =~ Render.render_block(block, %{style: :article})
      controls = LazyHTML.query(tree, "details#note-controls-n.bp-paper-contextual-controls")
      assert Enum.count(controls) == 1
      assert LazyHTML.attribute(controls, "open") == []
      assert LazyHTML.attribute(controls, "phx-mounted") != []

      summary = LazyHTML.query(controls, "summary.bp-paper-contextual-toggle")
      assert LazyHTML.text(summary) == "Read-only note"
      assert LazyHTML.attribute(summary, "tabindex") == []
      assert LazyHTML.attribute(summary, "hidden") == []
      assert LazyHTML.attribute(summary, "aria-hidden") == []

      # Native details reveals this direct child panel on open; no script or
      # writable form is required to read the explanation.
      message = LazyHTML.query(controls, ".bp-paper-contextual-panel > .bp-paper-edit-readonly")
      assert Enum.count(message) == 1

      assert LazyHTML.text(message) ==
               "This note has content that cannot be edited safely here. Its original content is preserved."

      assert Enum.empty?(
               LazyHTML.query(tree, ".bp-paper-contextual-editor > .bp-paper-edit-readonly")
             )

      assert Enum.empty?(
               LazyHTML.query(
                 controls,
                 "form, input, textarea, select, button, [contenteditable]"
               )
             )

      assert Enum.empty?(LazyHTML.query(tree, "[name^='note-']"))
      assert Enum.empty?(LazyHTML.query(tree, "#note-form-n"))

      preview = LazyHTML.query(tree, "[data-test-id='paper-note-preview'] > *")
      expected = block |> Render.render_block(%{style: :article}) |> LazyHTML.from_fragment()
      assert LazyHTML.to_html(preview) == LazyHTML.to_html(expected)
    end
  end

  test "read-only note disclosure reuses the keyboard-focus contextual affordance" do
    css = File.read!("priv/static/assets/bp-paper-editor-shell.css")
    assert css =~ ".bp-paper-contextual-editor:focus-within > .bp-paper-contextual-controls,"
    assert css =~ ".bp-paper-contextual-controls[open] { opacity: 1; pointer-events: auto; }"
  end
end
