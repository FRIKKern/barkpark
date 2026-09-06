defmodule BarkparkWeb.Studio.PaperEditor.TabsEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  test "Tabs are creatable and retain reader-style labelled panels with scoped Paper canvases" do
    menu_html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: [],
        canvas_eligible: true
      )

    assert menu_html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("option[value='tabs']")
           |> LazyHTML.text() == "Tabs"

    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: tabs(),
        root_slug: "paper",
        canvas_enabled: true,
        paper_rev: 3
      )

    assert html =~ ~s(class="bp-tabs bp-tabs--editor")
    assert html =~ ~s(class="bp-tabs__section")
    assert html =~ ~s(class="bp-tabs__label")
    assert html =~ "Overview"
    assert html =~ ~s(data-paper-container-kind="tabs")
    assert html =~ ~s(data-paper-container-row-id="panel-one")
    assert html =~ ~s(data-paper-container-id="tabs")

    assert html =~
             "paper-canvas-" <>
               PaperCanvas.run_id(PaperCanvas.tabs_run_slug("paper", "tabs", "panel-one"), 0)

    refute html =~ "blocks are not editable yet"
  end

  test "generic Beta exposes each panel body through per-block rich editors" do
    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: tabs(),
        root_slug: "paper",
        canvas_enabled: false
      )

    assert html =~ ~s(id="paper-ed-panel-body")
    refute html =~ ~s(phx-hook="BarkparkPaperCanvas")
    refute html =~ "blocks are not editable yet"
  end

  test "panel controls submit stable identities and never nest forms inside body editors" do
    html = render_component(&PaperEditor.paper_block_fields/1, block: tabs(), root_slug: "paper")
    tree = LazyHTML.from_fragment(html)

    assert Enum.empty?(LazyHTML.query(tree, "form form"))
    refute Enum.empty?(LazyHTML.query(tree, "fieldset.bp-paper-edit-form"))
    refute Enum.empty?(LazyHTML.query(tree, "fieldset label.bp-paper-edit-fieldlabel"))
    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='panel-count']"), "value") == ["1"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='panel-0-id']"), "value") == [
             "panel-one"
           ]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='panel-0-label']"), "value") == [
             "Overview"
           ]

    assert LazyHTML.attribute(LazyHTML.query(tree, "button[name='panel-action']"), "value") == [
             "up:panel-one",
             "down:panel-one",
             "remove:panel-one",
             "add"
           ]
  end

  test "missing and nil panel collections initialize safely" do
    for block <- [
          %{"id" => "tabs", "type" => "tabs"},
          %{"id" => "tabs", "type" => "tabs", "tabs" => nil}
        ] do
      html = render_component(&PaperEditor.paper_block_fields/1, block: block)
      assert html =~ ~s(id="tabs-form-tabs")
      assert html =~ ~s(name="panel-count" value="0")
    end
  end

  test "blank labels get an accessible display fallback without rewriting the authored value" do
    block =
      tabs()
      |> put_in(["tabs", Access.at(0), "label"], "   ")

    html = render_component(&PaperEditor.paper_block_fields/1, block: block)
    tree = LazyHTML.from_fragment(html)

    assert tree |> LazyHTML.query(".bp-tabs__label") |> LazyHTML.text() |> String.trim() ==
             "Tab 1"

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='panel-0-label']"), "value") == [
             "   "
           ]
  end

  test "malformed panels remain visible through the canonical preview and expose no unsafe controls" do
    for panels <- [
          "legacy",
          [%{"id" => "panel", "label" => %{"legacy" => true}, "blocks" => []}],
          [%{"id" => "panel", "label" => "Keep", "blocks" => "legacy"}],
          [%{"id" => "panel", "label" => "Keep", "blocks" => ["legacy"]}],
          [%{"id" => "   ", "label" => "Whitespace identity", "blocks" => []}],
          [%{"id" => "duplicate", "label" => "One"}, %{"id" => "duplicate", "label" => "Two"}],
          [%{"label" => "Missing identity", "blocks" => []}]
        ] do
      html =
        render_component(&PaperEditor.paper_block_fields/1,
          block: %{"id" => "tabs", "type" => "tabs", "tabs" => panels}
        )

      assert html =~ "original content is preserved"
      refute html =~ ~s(id="tabs-form-tabs")
      refute html =~ ~s(name="panel-action")
    end
  end

  test "Beta footer counts canonical panel bodies and excludes panel labels and opaque aliases" do
    blocks = [
      %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [
          %{
            "id" => "panel-one",
            "label" => "excluded label words",
            "blocks" => [paragraph("visible", "one two three")],
            "children" => [paragraph("opaque", "shadow words must not count")]
          },
          %{"id" => "panel-two", "label" => "also excluded", "blocks" => nil}
        ]
      }
    ]

    footer =
      render_component(&PaperEditor.paper_block_editor/1, slug: "word-count", blocks: blocks)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test-id="bp-paper-footer"]))
      |> LazyHTML.text()

    assert footer =~ "3 words"
    assert footer =~ "1 blocks"
  end

  defp tabs do
    %{
      "id" => "tabs",
      "type" => "tabs",
      "tabs" => [
        %{
          "id" => "panel-one",
          "label" => "Overview",
          "blocks" => [paragraph("panel-body", "Panel body")],
          "unknown" => "preserve"
        }
      ]
    }
  end

  defp paragraph(id, words) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => words}]
    }
  end
end
