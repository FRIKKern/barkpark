defmodule BarkparkWeb.Studio.PaperEditor.ActionContextualEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  @editor_shell_css Path.expand(
                      "../../../../../priv/static/assets/bp-paper-editor-shell.css",
                      __DIR__
                    )

  test "canonical Action renders its reader preview and accessible authored fields" do
    action = %{
      "id" => "action",
      "type" => "action",
      "label" => "Read the report",
      "href" => "/report",
      "priority" => "primary",
      "unknown" => %{"kept" => true}
    }

    html = render_fields(action)
    tree = LazyHTML.from_fragment(html)
    preview = LazyHTML.query(tree, "[data-test-id='paper-action-preview']")
    form = LazyHTML.query(tree, "#action-form-action")

    assert html =~ Render.render_block(action, %{style: :article})
    assert Enum.count(LazyHTML.query(preview, "a.bp-button.bp-button--primary")) == 1
    assert form_value(form, "action-label") == ["Read the report"]
    assert form_value(form, "action-href") == ["/report"]
    assert selected_value(form, "action-priority") == ["primary"]

    assert LazyHTML.attribute(LazyHTML.query(form, "label[for='action-label-action']"), "for") ==
             ["action-label-action"]

    controls = LazyHTML.query(tree, "#action-controls-action")
    assert LazyHTML.attribute(controls, "open") == []
    assert Enum.count(LazyHTML.query(tree, "form")) == 1
    refute html =~ "blocks are not editable yet"

    css = File.read!(@editor_shell_css)
    assert css =~ ".bp-paper-contextual-controls--action[open]"

    assert css =~
             ".bp-paper-contextual-controls--action[open] > .bp-paper-contextual-panel"
  end

  test "blank Action remains configurable and unknown binary priority is preserved as an option" do
    blank_tree =
      %{"id" => "blank", "type" => "action"}
      |> render_fields()
      |> LazyHTML.from_fragment()

    blank_form = LazyHTML.query(blank_tree, "#action-form-blank")

    assert form_value(blank_form, "action-label") == [""]
    assert form_value(blank_form, "action-href") == [""]
    assert selected_value(blank_form, "action-priority") == ["secondary"]

    assert LazyHTML.attribute(LazyHTML.query(blank_tree, "#action-controls-blank"), "class") == [
             "bp-paper-contextual-controls bp-paper-contextual-controls--action bp-paper-contextual-controls--action-empty"
           ]

    assert File.read!(@editor_shell_css) =~ ".bp-paper-contextual-controls--action-empty"

    unknown_form =
      %{
        "id" => "unknown",
        "type" => "action",
        "label" => "Quiet",
        "href" => "/quiet",
        "priority" => "quiet"
      }
      |> render_fields()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#action-form-unknown")

    assert selected_value(unknown_form, "action-priority") == ["quiet"]
    assert Enum.count(LazyHTML.query(unknown_form, "option[value='quiet']")) == 1
  end

  test "malformed authored fields retain the canonical preview and expose no editor" do
    for action <- [
          %{
            "id" => "bad-label",
            "type" => "action",
            "label" => %{"opaque" => true},
            "href" => "/visible"
          },
          %{"id" => "bad-href", "type" => "action", "label" => "Visible", "href" => ["opaque"]},
          %{"id" => "bad-priority", "type" => "action", "label" => "Visible", "priority" => 7}
        ] do
      html = render_fields(action)
      tree = LazyHTML.from_fragment(html)

      assert html =~ ~s(data-test-id="paper-action-preview")
      assert html =~ Render.render_block(action, %{style: :article})
      assert html =~ "original content is preserved"
      refute html =~ ~s(data-test-id="paper-action-editor")
      refute html =~ "blocks are not editable yet"
      assert Enum.empty?(LazyHTML.query(tree, "form"))
    end
  end

  test "an Action inside a grid Section remains one authored cell child without a singleton canvas" do
    section = %{
      "id" => "section",
      "type" => "section",
      "layout" => %{"mode" => "grid", "tracks" => 2},
      "blocks" => [
        %{
          "id" => "action",
          "type" => "action",
          "label" => "Open",
          "href" => "/open",
          "span" => 2,
          "order" => 1,
          "unknown" => true
        }
      ]
    }

    tree = section |> render_fields(canvas_enabled: true) |> LazyHTML.from_fragment()
    cells = LazyHTML.query(tree, ".bp-section__grid > .bp-section__cell")

    assert Enum.count(cells) == 1
    assert LazyHTML.attribute(cells, "style") == ["grid-column:span 2;order:1"]

    assert Enum.count(LazyHTML.query(cells, "[data-test-id='paper-action-contextual-editor']")) ==
             1

    assert Enum.count(LazyHTML.query(cells, "#action-form-action")) == 1
    assert Enum.empty?(LazyHTML.query(cells, "[data-test-id='paper-canvas-run']"))
  end

  test "Add block offers Action and Card and both defaults open their contextual controls" do
    menu =
      render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: [])
      |> LazyHTML.from_fragment()

    assert Enum.count(
             LazyHTML.query(menu, "[data-test-id='paper-add-block'] option[value='action']")
           ) ==
             1

    assert Enum.count(
             LazyHTML.query(menu, "[data-test-id='paper-add-block'] option[value='card']")
           ) ==
             1

    action = Blocks.default_block("action", "new-action")
    card = Blocks.default_block("card", "new-card")

    assert Enum.count(
             action
             |> render_fields()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#action-form-new-action")
           ) == 1

    assert Enum.count(
             card
             |> render_fields()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#card-form-new-card")
           ) == 1
  end

  defp render_fields(block, opts \\ []) do
    render_component(
      &PaperEditor.paper_block_fields/1,
      [
        block: block,
        root_slug: "paper",
        doc_key: "production:paper:paper",
        paper_rev: 7
      ] ++ opts
    )
  end

  defp form_value(form, name) do
    form
    |> LazyHTML.query("[name='#{name}']")
    |> LazyHTML.attribute("value")
  end

  defp selected_value(form, name) do
    form
    |> LazyHTML.query("select[name='#{name}'] option[selected]")
    |> LazyHTML.attribute("value")
  end
end
