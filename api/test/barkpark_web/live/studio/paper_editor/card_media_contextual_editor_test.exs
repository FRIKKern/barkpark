defmodule BarkparkWeb.Studio.PaperEditor.CardMediaContextualEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "a singleton authored image rests as the canonical reader paint with one direct picker" do
    for media <- [
          image(%{"type" => "image"}),
          image(%{})
        ] do
      card_id = "card: media/[cover]#?"
      block = card(card_id, media)
      html = render_fields(block, picker_browse: true)
      tree = LazyHTML.from_fragment(html)
      preview = LazyHTML.query(tree, "[data-test-id='paper-card-image-preview']")
      trigger = LazyHTML.query(preview, "[data-test-id='paper-card-image-edit-trigger']")
      picker_shell = LazyHTML.query(preview, "[data-test-id='paper-card-image-picker']")
      picker = LazyHTML.query(picker_shell, "[data-paper-figure-image-picker]")
      configure = LazyHTML.query(tree, "[data-test-id='paper-card-image-focus']")
      expected_id = "card-image-" <> Base.url_encode64(card_id, padding: false)

      reader_html = Render.render_block(Map.put_new(media, "type", "image"), %{style: :article})
      assert reader_html =~ ~s(data-bp-lightboxable="true")
      assert html =~ String.replace(reader_html, ~s( data-bp-lightboxable="true"), "")
      refute html =~ ~s(data-bp-lightboxable="true")

      assert LazyHTML.attribute(preview, "id") == [expected_id]
      assert LazyHTML.attribute(preview, "phx-hook") == ["BarkparkFigureImageBridge"]
      assert LazyHTML.attribute(preview, "data-image-owner") == ["card"]
      assert LazyHTML.attribute(preview, "data-block-id") == [card_id]
      assert LazyHTML.attribute(preview, "data-image-src") == ["/media/cover.jpg"]
      assert expected_id =~ ~r/^card-image-[A-Za-z0-9_-]+$/

      assert Enum.count(LazyHTML.query(preview, "img")) == 1
      image = LazyHTML.query(preview, "img")
      assert LazyHTML.attribute(image, "src") == ["/media/cover.jpg"]
      assert LazyHTML.attribute(image, "alt") == ["Authored cover"]
      assert LazyHTML.attribute(image, "width") == ["960"]
      assert LazyHTML.attribute(image, "height") == ["540"]

      assert Enum.count(picker) == 1
      assert LazyHTML.attribute(picker, "value") == ["/media/cover.jpg"]
      assert LazyHTML.attribute(picker, "dataset") == ["production"]
      assert LazyHTML.attribute(picker, "scope-prefix") == ["/w/default/p/default"]
      assert LazyHTML.attribute(picker, "data-token") == ["writer-token"]
      assert LazyHTML.attribute(picker_shell, "open") == []

      assert LazyHTML.attribute(trigger, "id") == [expected_id <> "-trigger"]
      assert LazyHTML.attribute(trigger, "type") == ["button"]
      assert LazyHTML.attribute(trigger, "aria-haspopup") == ["dialog"]
      assert LazyHTML.attribute(trigger, "aria-label") == ["Replace card image: Authored cover"]
      assert LazyHTML.attribute(configure, "aria-controls") == [expected_id <> "-trigger"]
      assert hd(LazyHTML.attribute(configure, "phx-click")) =~ "##{expected_id}-trigger"

      assert Enum.empty?(LazyHTML.query(tree, "input[name='card-media-src']"))
      assert Enum.count(LazyHTML.query(tree, "[data-paper-figure-image-picker]")) == 1
      assert Enum.count(LazyHTML.query(tree, "[data-test-id='paper-card-image-preview']")) == 1
    end
  end

  test "null empty and missing image sources retain the explicit source fallback" do
    media_variants = [
      %{"type" => "image", "src" => nil, "alt" => "Null source"},
      %{"type" => "image", "src" => "", "alt" => "Empty source"},
      %{"type" => "image", "alt" => "Missing source"}
    ]

    for {media, index} <- Enum.with_index(media_variants) do
      tree =
        "fallback-#{index}"
        |> card(media)
        |> render_fields(picker_browse: true)
        |> LazyHTML.from_fragment()

      assert Enum.count(LazyHTML.query(tree, "[data-test-id='paper-card-editor']")) == 1
      assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-card-image-preview']"))
      assert Enum.empty?(LazyHTML.query(tree, "[data-paper-figure-image-picker]"))
      assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-card-image-focus']"))

      assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='card-media-src']"), "value") ==
               [""]
    end
  end

  test "malformed media remains reader-painted and read-only instead of entering direct editing" do
    malformed = [
      %{"id" => "scalar", "type" => "card", "slots" => %{"media" => ["opaque"]}},
      %{
        "id" => "multiple",
        "type" => "card",
        "slots" => %{"media" => [image(%{}), image(%{"src" => "/media/second.jpg"})]}
      },
      %{
        "id" => "wrong-type",
        "type" => "card",
        "slots" => %{"media" => [%{"type" => "paragraph", "src" => "/not-an-image.jpg"}]}
      }
    ]

    for block <- malformed do
      html = render_fields(block, picker_browse: true)
      tree = LazyHTML.from_fragment(html)

      assert html =~ Render.render_block(block, %{style: :article})
      assert html =~ "original content is preserved"
      assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-card-editor']"))
      assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-card-image-preview']"))
      assert Enum.empty?(LazyHTML.query(tree, "[data-paper-figure-image-picker]"))
      assert Enum.empty?(LazyHTML.query(tree, "input[name='card-media-src']"))
    end
  end

  defp render_fields(block, opts) do
    render_component(&PaperEditor.paper_block_fields/1,
      block: block,
      root_slug: "paper",
      doc_key: "production:paper:paper",
      paper_rev: 7,
      dataset: "production",
      scope_prefix: "/w/default/p/default",
      api_token_raw: "writer-token",
      picker_browse: Keyword.fetch!(opts, :picker_browse)
    )
  end

  defp card(id, media),
    do: %{
      "id" => id,
      "type" => "card",
      "slots" => %{
        "title" => [%{"type" => "heading", "level" => 3, "text" => "Card title"}],
        "body" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Card body"}]
          }
        ],
        "media" => [media]
      }
    }

  defp image(extra),
    do:
      Map.merge(
        %{
          "src" => "/media/cover.jpg",
          "alt" => "Authored cover",
          "width" => 960,
          "height" => 540,
          "opaque" => %{"assetId" => "asset-1"}
        },
        extra
      )
end
