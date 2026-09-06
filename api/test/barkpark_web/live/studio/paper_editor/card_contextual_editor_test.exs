defmodule BarkparkWeb.Studio.PaperEditor.CardContextualEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  @editor_shell_css Path.expand(
                      "../../../../../priv/static/assets/bp-paper-editor-shell.css",
                      __DIR__
                    )

  test "canonical Card renders reader preview and strict chrome fields without flattening body" do
    card = %{
      "id" => "card",
      "type" => "card",
      "tone" => "info",
      "slots" => %{
        "title" => [%{"type" => "heading", "text" => "Card title", "unknown" => true}],
        "body" => [paragraph("Card body")],
        "media" => [%{"type" => "image", "src" => "/image.png", "alt" => "Cover"}],
        "action" => [
          %{
            "type" => "action",
            "label" => "Read",
            "href" => "/read",
            "priority" => "primary"
          }
        ],
        "unknown-slot" => [%{"opaque" => true}]
      }
    }

    html = render_fields(card)
    tree = LazyHTML.from_fragment(html)
    preview = LazyHTML.query(tree, "[data-test-id='paper-card-preview']")
    form = LazyHTML.query(tree, "#card-form-card")

    assert LazyHTML.attribute(LazyHTML.query(preview, ".bp-card"), "class") == [
             "bp-card bp-card--info"
           ]

    assert html =~ "Card title"
    assert html =~ "Card body"
    assert html =~ ~s(src="/image.png")
    assert html =~ ~s(href="/read")

    assert form_value(form, "card-title") == ["Card title"]
    assert form_value(form, "card-media-src") == ["/image.png"]
    assert form_value(form, "card-media-alt") == ["Cover"]
    assert form_value(form, "card-action-label") == ["Read"]
    assert form_value(form, "card-action-href") == ["/read"]
    assert selected_value(form, "card-action-priority") == ["primary"]
    assert selected_value(form, "card-tone") == ["info"]
    assert Enum.empty?(LazyHTML.query(form, "[name*='body'], textarea"))
    assert Enum.count(LazyHTML.query(tree, "form")) == 1
    assert Enum.count(LazyHTML.query(tree, "bp-paper-editor[data-editor-mode='card-body']")) == 1

    controls = LazyHTML.query(tree, "#card-controls-card")
    assert LazyHTML.attribute(controls, "open") == []

    css = File.read!(@editor_shell_css)
    assert css =~ ".bp-paper-contextual-controls--card[open]"

    assert css =~
             ".bp-paper-contextual-controls--card[open] > .bp-paper-contextual-panel"
  end

  test "missing slots are editable and unknown binary selections remain selectable unchanged" do
    empty_html = render_fields(%{"id" => "empty", "type" => "card"})
    empty_form = LazyHTML.query(LazyHTML.from_fragment(empty_html), "#card-form-empty")

    assert form_value(empty_form, "card-title") == [""]
    assert selected_value(empty_form, "card-action-priority") == ["secondary"]

    unknown_html =
      render_fields(%{
        "id" => "unknown",
        "type" => "card",
        "tone" => "violet",
        "slots" => %{
          "action" => [
            %{"type" => "action", "label" => "Go", "href" => "/go", "priority" => "quiet"}
          ]
        }
      })

    unknown_form = LazyHTML.query(LazyHTML.from_fragment(unknown_html), "#card-form-unknown")
    assert selected_value(unknown_form, "card-tone") == ["violet"]
    assert selected_value(unknown_form, "card-action-priority") == ["quiet"]
    assert Enum.count(LazyHTML.query(unknown_form, "option[value='violet']")) == 1
    assert Enum.count(LazyHTML.query(unknown_form, "option[value='quiet']")) == 1
  end

  test "malformed and multi-element known slots remain reader-previewed and read-only" do
    malformed = [
      %{"id" => "scalar", "type" => "card", "slots" => "opaque"},
      %{
        "id" => "multi",
        "type" => "card",
        "slots" => %{"title" => [%{"type" => "heading"}, %{"type" => "heading"}]}
      },
      %{
        "id" => "wrong-type",
        "type" => "card",
        "slots" => %{"media" => [%{"type" => "paragraph", "content" => []}]}
      }
    ]

    for card <- malformed do
      html = render_fields(card)
      assert html =~ ~s(data-test-id="paper-card-preview")
      assert html =~ "original content is preserved"
      refute html =~ ~s(data-test-id="paper-card-editor")
      refute html =~ "blocks are not editable yet"
    end
  end

  test "a Card inside a grid Section remains exactly one authored cell child" do
    section = %{
      "id" => "section",
      "type" => "section",
      "layout" => %{"mode" => "grid", "tracks" => 2},
      "blocks" => [
        %{
          "id" => "card",
          "type" => "card",
          "span" => 2,
          "order" => 1,
          "slots" => %{"body" => [paragraph("Grid body")]}
        }
      ]
    }

    tree = section |> render_fields() |> LazyHTML.from_fragment()
    cells = LazyHTML.query(tree, ".bp-section__grid > .bp-section__cell")

    assert Enum.count(cells) == 1
    assert LazyHTML.attribute(cells, "style") == ["grid-column:span 2;order:1"]
    assert Enum.count(LazyHTML.query(cells, "[data-test-id='paper-card-contextual-editor']")) == 1
    assert Enum.count(LazyHTML.query(cells, "#card-form-card")) == 1
    assert Enum.count(LazyHTML.query(cells, "form")) == 1
  end

  defp render_fields(block) do
    render_component(&PaperEditor.paper_block_fields/1,
      block: block,
      root_slug: "paper",
      doc_key: "production:paper:paper",
      paper_rev: 7
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

  defp paragraph(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
end
