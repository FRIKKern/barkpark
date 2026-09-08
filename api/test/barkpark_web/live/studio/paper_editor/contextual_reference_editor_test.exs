defmodule BarkparkWeb.Studio.PaperEditor.ContextualReferenceEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "inline summaries patch only text while settings explicitly control default-open" do
    for open <- [nil, false, true] do
      block = %{"type" => "expandable", "open" => open}

      assert Blocks.build_block_patch(block, %{"summary" => "Updated"}) == %{
               "summary" => "Updated"
             }

      assert Blocks.build_block_patch(block, %{"open" => "false"}) == %{"open" => false}
      assert Blocks.build_block_patch(block, %{"open" => "true"}) == %{"open" => true}
    end
  end

  test "paper-links keeps canonical cards and exposes one direct scalar editor per header field" do
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

    live_details = %{
      "release-week" => %{
        title: "Release week, live",
        description: "The published account",
        event_type: "release"
      }
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: block,
        paper_links: live_details
      })

    assert html =~ "Release week, live"
    refute html =~ ">Release week</a>"
    assert html =~ ~s(data-test-id="paper-links-preview")
    assert html =~ ~s(class="bp-paper-links-header-editor")
    assert html =~ ~s(class="bp-paper-links-title-heading")
    assert html =~ ~s(data-paper-links-title-paint)
    assert html =~ ~s(class="bp-paper-links-description-paragraph")
    assert html =~ ~s(data-paper-links-description-paint)
    assert html =~ ~s(id="paper-links-title-cmVsYXRlZA")
    assert html =~ ~s(id="paper-links-description-cmVsYXRlZA")
    assert html =~ ~s(data-test-id="paper-links-title-editor")
    assert html =~ ~s(data-test-id="paper-links-description-editor")
    assert html =~ ~s(phx-hook="BarkparkPaperAutoSize")
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"
    assert html =~ ~s(id="paper-links-form-related")
    assert html =~ ~s(phx-submit="paper-edit-block")
    assert html =~ ~s(phx-change="paper-block-autosave")
    assert html =~ ~s(type="hidden" name="ref-0-featured" value="false")
    assert html =~ ~s(type="checkbox" name="ref-0-featured" value="true")

    fragment = LazyHTML.from_fragment(html)

    assert fragment |> LazyHTML.query(~s(textarea[name="title"])) |> Enum.count() == 1
    assert fragment |> LazyHTML.query(~s(textarea[name="description"])) |> Enum.count() == 1
    assert fragment |> LazyHTML.query("h2 form, p form, form form") |> Enum.empty?()

    assert fragment
           |> LazyHTML.query(~s(#paper-links-form-related [name="title"]))
           |> Enum.empty?()

    assert fragment
           |> LazyHTML.query(~s(#paper-links-form-related [name="description"]))
           |> Enum.empty?()
  end

  test "paper-links default heading stays paint-only and hostile ids get safe focus targets" do
    block = %{
      "id" => "related: with punctuation!?",
      "type" => "paper-links",
      "refs" => []
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block, paper_links: %{}})
    encoded = Base.url_encode64(block["id"], padding: false)
    fragment = LazyHTML.from_fragment(html)

    assert html =~ "Explore the work"
    refute html =~ ~s(<section data-paper-links)

    assert fragment
           |> LazyHTML.query(~s(textarea#paper-links-title-#{encoded}[name="title"]))
           |> LazyHTML.text() == ""

    assert fragment
           |> LazyHTML.query(~s(input[name="block_id"][value="related: with punctuation!?"]))
           |> Enum.count() == 3

    assert fragment
           |> LazyHTML.query(
             ~s([data-paper-links-title-panel-trigger][aria-controls="paper-links-title-#{encoded}"])
           )
           |> Enum.count() == 1
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
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"
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
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"
    assert html =~ ~s(id="expandable-form-details")
    assert html =~ ~s(phx-hook="BarkparkPaperCanvas")
    assert html =~ ~s(data-paper-container-id="details")
    assert html =~ ~s(data-paper-doc-key="production:paper:chronicle")
    assert html =~ ~s(data-paper-rev="7")

    fragment = LazyHTML.from_fragment(html)

    assert fragment
           |> LazyHTML.query(
             ~s(details.bp-expandable > summary textarea[name="summary"][form="expandable-summary-form-details"][aria-label="Expandable title"])
           )
           |> LazyHTML.text() == "Technical record"

    assert fragment |> LazyHTML.query("summary form, form form") |> Enum.empty?()

    assert fragment
           |> LazyHTML.query(~s(#expandable-form-details input[name="summary"]))
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             ~s(#expandable-form-details input[name="open"][type="hidden"][value="false"])
           )
           |> Enum.count() == 1

    for disclosure <- LazyHTML.query(fragment, "details") do
      assert [_id] = LazyHTML.attribute(disclosure, "id")
      assert [command] = LazyHTML.attribute(disclosure, "phx-mounted")
      assert [["ignore_attrs", %{"attrs" => ["open"]}]] = Jason.decode!(command)
    end

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
