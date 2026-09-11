defmodule BarkparkWeb.Studio.SharedPaperCardsRenderTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Components
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "legacy Cards bind exact authored items without rewriting reader HTML or source" do
    block = %{
      "id" => "legacy-cards",
      "type" => "cards",
      "items" => [
        nil,
        %{
          "id" => "first",
          "title" => " Authored title ",
          "text" => "Visible body",
          "tone" => "info",
          "href" => "/unchanged",
          "audit" => %{"keep" => true}
        },
        %{"title" => 12.5, "text" => "Numeric carrier", "custom" => [1, 2]}
      ],
      "audit" => %{"collection" => true}
    }

    paint = Paper.fleet_render(block, %{})
    assert paint["source_block"] === block
    assert paint["html"] == Render.render_block(block, %{style: :article})
    assert paint["html"] == Components.cards_html(block)
    assert paint["html"] =~ "Authored title"
    refute paint["html"] =~ "contenteditable"
  end
end
