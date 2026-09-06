defmodule BarkparkWeb.Studio.PaperEditor.ContextualReferenceEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "paper-links keeps the reader render visible and its existing form closed contextually" do
    block = %{
      "id" => "related",
      "type" => "paper-links",
      "title" => "Related reading",
      "description" => "Follow the release story.",
      "refs" => [
        %{
          "slug" => "release-week",
          "title" => "Release week",
          "description" => "The full account"
        }
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

    assert html =~ Render.render_block(block, %{style: :article})
    assert html =~ ~s(data-test-id="paper-links-preview")
    assert html =~ ~s(<details class="bp-paper-contextual-controls">)
    assert html =~ ~s(id="paper-links-form-related")
    assert html =~ ~s(phx-submit="paper-edit-block")
    assert html =~ ~s(phx-change="paper-block-autosave")
    assert html =~ ~s(type="hidden" name="ref-0-featured" value="false")
    assert html =~ ~s(type="checkbox" name="ref-0-featured" value="true")
  end

  test "bar-chart keeps the canonical chart visible while row controls start closed" do
    block = %{
      "id" => "velocity",
      "type" => "bar-chart",
      "title" => "Changes by kind",
      "max" => 8,
      "values" => true,
      "bars" => [
        %{"label" => "Features", "value" => 8},
        %{"label" => "Fixes", "value" => 5}
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

    assert html =~ Render.render_block(block, %{style: :article})
    assert html =~ ~s(data-test-id="paper-bar-chart-preview")
    assert html =~ ~s(<details class="bp-paper-contextual-controls">)
    assert html =~ ~s(id="bar-chart-form-velocity")
    assert html =~ ~s(data-test-id="paper-bar-chart-row")
    assert html =~ ~s(phx-debounce="500")
  end

  test "expandable preview stays rendered and its closed controls retain nested canvas context" do
    block = %{
      "id" => "details",
      "type" => "expandable",
      "summary" => "Technical record",
      "children" => [
        %{
          "id" => "nested-copy",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "The preserved nested prose."}]
        }
      ]
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: block,
        canvas_enabled: true,
        root_slug: "chronicle",
        doc_key: "production:paper:chronicle",
        paper_rev: 7
      })

    assert html =~ ~s(data-test-id="paper-expandable-preview")
    assert html =~ ~s(<details class="bp-paper-contextual-controls">)
    assert html =~ ~s(id="expandable-form-details")
    assert html =~ ~s(phx-hook="BarkparkPaperCanvas")
    assert html =~ ~s(data-paper-container-id="details")
    assert html =~ ~s(data-paper-doc-key="production:paper:chronicle")
    assert html =~ ~s(data-paper-rev="7")

    fragment = LazyHTML.from_fragment(html)

    assert fragment
           |> LazyHTML.query(
             ~s(details.bp-expandable > .bp-expandable__body > [phx-hook="BarkparkPaperCanvas"])
           )
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query("details.bp-paper-contextual-controls:not([open])")
           |> Enum.count() == 1

    assert fragment |> LazyHTML.query("details.bp-expandable") |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             ~s(details.bp-paper-contextual-controls [phx-hook="BarkparkPaperCanvas"])
           )
           |> Enum.count() == 0

    ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
    assert length(ids) == length(Enum.uniq(ids))
  end
end
